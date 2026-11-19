-- Admin-level setup that Azure Database for PostgreSQL does through its extension allow-list.
-- Roles, schemas and tables come from each service's migrations, not from here.
CREATE EXTENSION IF NOT EXISTS vector;
