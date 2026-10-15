# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "../support/csr_fixtures"

class CsrDeletionConcurrencyTest < ActiveSupport::TestCase
  include CsrFixtures

  self.use_transactional_tests = false

  teardown do
    CsrCertificate.where(certificate_request_id: @csr.id).delete_all if @csr
    AuditEvent.where("details ->> 'csr_id' = ?", @csr.id.to_s).delete_all if @csr
    @csr&.destroy!
  end

  test "upload and delete serialize and only one succeeds in either lock order" do
    %i[delete upload].each do |first_action|
      @csr = create_csr
      data = issued_for(@csr).to_pem
      locked = Queue.new
      release = Queue.new
      second_pid = Queue.new
      first = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          request = CertificateRequest.find(@csr.id)
          request.with_lock do
            locked << true
            release.pop
            mutate(first_action, request, data)
          end
        end
      end
      locked.pop
      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          second_pid << connection.select_value("SELECT pg_backend_pid()")
          mutate(first_action == :delete ? :upload : :delete, CertificateRequest.find(@csr.id), data)
        end
      rescue Certificates::Error => e
        e
      end
      pid = second_pid.pop
      Timeout.timeout(10) do
        loop do
          blocked = ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))")
          end
          break if blocked.positive?

          Thread.pass
        end
      end
      release << true
      first.value
      assert_instance_of Certificates::Error, second.value
      assert_equal first_action == :delete, @csr.reload.deleted_at.present?
      assert_equal first_action == :upload ? 1 : 0, @csr.csr_certificates.count
      CsrCertificate.where(certificate_request_id: @csr.id).delete_all
      AuditEvent.where("details ->> 'csr_id' = ?", @csr.id.to_s).delete_all
      @csr.destroy!
      @csr = nil
    ensure
      release << true if release
      [first, second].compact.each { |thread| thread.join(15) || thread.kill }
    end
  end

  private

  def mutate(action, request, data)
    if action == :delete
      CsrWorkflow.delete(request, identity: csr_identity, confirmed: true)
    else
      CsrUpload.call(request, data: data, identity: csr_identity)
    end
  end
end
