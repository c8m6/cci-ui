# Project conventions

- Write all project documentation in English, including new documents, updates
  to existing documentation, and comments in documentation examples.
- Preserve exact UI labels and other literal values when documenting them.
- After completing changes, rebuild and start the development containers with
  `docker compose -f compose.yml up --build -d --wait` so the current changes are
  immediately available for manual testing. Verify that the application responds
  at `http://localhost:3000` and leave the development containers running.
