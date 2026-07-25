CREATE TABLE agents (
  id text PRIMARY KEY,
  team_id text NOT NULL REFERENCES teams (id)
);
