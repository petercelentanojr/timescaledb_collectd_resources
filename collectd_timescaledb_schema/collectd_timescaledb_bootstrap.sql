-- Author:
-- ------------
-- Peter S Celentano Jr
--
-- Description:
-- ------------
--
-- This is an example schema for storing collectd metrics in a TimescaleDB
-- database (see https://www.timescale.com/).  It is based on the PostgreSQL
-- schema contributed by Lars Kellogg-Stedman.  In addition to creating a 
-- collectd compatable schema for use with TimescaleDB, it will also create
-- this schema inside of a database named "collectd", and create a new 
-- read-only user on your database instance that is appropriate for the
-- purpose of connecting TimescaleDB to Grafana.  Please modify it as 
-- your usecase allows.
--
-- Prerequisities:
-- ---------------
--
-- 1). A running PostgreSQL database with TimescaleDB enabled
-
-- 2). Access to a superuser account on the above mentioned database
--
-- Directions:
-- -----------
--
-- Run this schema against the desired metrics database using your prefered
-- tool.  Here is an example using psql:
--
-- Ex. <psql -h 192.168.55.101 -p 5432 -U postgres -f collectd_timescaledb_bootstrap.sql>

CREATE DATABASE collectd;

\c collectd

CREATE EXTENSION timescaledb;


CREATE TABLE identifiers (
    id integer NOT NULL PRIMARY KEY,
    host character varying(64) NOT NULL,
    plugin character varying(64) NOT NULL,
    plugin_inst character varying(64) DEFAULT NULL::character varying,
    type character varying(64) NOT NULL,
    type_inst character varying(64) DEFAULT NULL::character varying,

    UNIQUE (host, plugin, plugin_inst, type, type_inst)
);

CREATE SEQUENCE identifiers_id_seq
    OWNED BY identifiers.id
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER TABLE identifiers
    ALTER COLUMN id
    SET DEFAULT nextval('identifiers_id_seq'::regclass);

CREATE INDEX identifiers_host ON identifiers USING btree (host);
CREATE INDEX identifiers_plugin ON identifiers USING btree (plugin);
CREATE INDEX identifiers_plugin_inst ON identifiers USING btree (plugin_inst);
CREATE INDEX identifiers_type ON identifiers USING btree (type);
CREATE INDEX identifiers_type_inst ON identifiers USING btree (type_inst);

CREATE TABLE "values" (
    id integer NOT NULL
        REFERENCES identifiers
        ON DELETE cascade,
    tstamp timestamp with time zone NOT NULL,
    name character varying(64) NOT NULL,
    value double precision NOT NULL,

    UNIQUE(tstamp, id, name)
);

SELECT create_hypertable('values', 'tstamp',
  chunk_time_interval => interval '1 day');

CREATE OR REPLACE VIEW collectd
    AS SELECT host, plugin, plugin_inst, type, type_inst,
            host
                || '/' || plugin
                || CASE
                    WHEN plugin_inst IS NOT NULL THEN '-'
                    ELSE ''
                END
                || coalesce(plugin_inst, '')
                || '/' || type
                || CASE
                    WHEN type_inst IS NOT NULL THEN '-'
                    ELSE ''
                END
                || coalesce(type_inst, '') AS identifier,
            tstamp, name, value
        FROM identifiers JOIN values ON values.id = identifiers.id;

CREATE OR REPLACE FUNCTION collectd_insert(
        timestamp with time zone, character varying,
        character varying, character varying,
        character varying, character varying,
        character varying[], character varying[], double precision[]
    ) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
    p_time alias for $1;
    p_host alias for $2;
    p_plugin alias for $3;
    p_plugin_instance alias for $4;
    p_type alias for $5;
    p_type_instance alias for $6;
    p_value_names alias for $7;
    -- don't use the type info; for 'StoreRates true' it's 'gauge' anyway
    -- p_type_names alias for $8;
    p_values alias for $9;
    ds_id integer;
    i integer;
BEGIN
    SELECT id INTO ds_id
        FROM identifiers
        WHERE host = p_host
            AND plugin = p_plugin
            AND COALESCE(plugin_inst, '') = COALESCE(p_plugin_instance, '')
            AND type = p_type
            AND COALESCE(type_inst, '') = COALESCE(p_type_instance, '');
    IF NOT FOUND THEN
        INSERT INTO identifiers (host, plugin, plugin_inst, type, type_inst)
            VALUES (p_host, p_plugin, p_plugin_instance, p_type, p_type_instance)
            RETURNING id INTO ds_id;
    END IF;
    i := 1;
    LOOP
        EXIT WHEN i > array_upper(p_value_names, 1);
        INSERT INTO values (id, tstamp, name, value)
            VALUES (ds_id, p_time, p_value_names[i], p_values[i]);
        i := i + 1;
    END LOOP;
END;
$_$;
-- create the monitoring user and set the password
DROP ROLE IF EXISTS monitoring;
CREATE ROLE monitoring;
REVOKE ALL PRIVILEGES ON database collectd FROM monitoring;
GRANT CONNECT ON DATABASE collectd TO monitoring;
ALTER ROLE monitoring WITH LOGIN;
GRANT USAGE ON SCHEMA public TO monitoring ;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO monitoring ;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO monitoring;
ALTER USER monitoring WITH PASSWORD 'password123';
