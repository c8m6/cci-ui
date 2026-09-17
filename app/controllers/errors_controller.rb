# This controller must work without authentication or database access, including
# when the failed request never reached an application controller.
class ErrorsController < ActionController::Base
  include WebContext
  include ErrorPages

  def show
    exception = request.env.fetch("action_dispatch.exception")
    status = ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
    render_error(status, exception: exception)
  end
end
