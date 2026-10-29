CREATE DOMAIN email AS text
CHECK (VALUE = lower(trim(VALUE)));

CREATE TABLE users (
  id uuid DEFAULT uuidv7() PRIMARY KEY,
  email email NOT NULL CONSTRAINT users_email_unique UNIQUE,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

REVOKE ALL ON flyway_schema_history FROM cloud_app;

CREATE FUNCTION f_set_updated_at() 
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER t_updated_at 
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION f_set_updated_at();
