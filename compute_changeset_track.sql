CREATE OR REPLACE FUNCTION compute_changeset_track()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_event_id BIGINT;
    v_payload  JSONB;

    -- Rule URIs
    psi5_uri  TEXT := 'https://ekg.example.org/mappings/psi5';
    psi7_uri  TEXT := 'https://ekg.example.org/mappings/psi7';
    psi8_uri  TEXT := 'https://ekg.example.org/mappings/psi8';
    psi12_uri TEXT := 'https://ekg.example.org/mappings/psi12';

BEGIN
    /*
      AFTER STATEMENT trigger for updates on TRACK.

      Input:
        D = deleted_TRACK
        I = inserted_TRACK

      The trigger computes, for each Ψ ∈ Relev(TRACK):
        - A_minus[Ψ](u)
        - A_plus[Ψ](u)
        - S2[Ψ](u), aggregated over A_minus[Ψ](u)
        - DeltaPlus[Ψ](u)

      It does NOT query GraphDB.
      The worker will later retrieve S1[Ψ](u) from GraphDB.
    */

    WITH

    ------------------------------------------------------------
    -- Ψ5: pivot-relevant rule
    -- Ψ5: mo:Track(s) <- Track(r), hasURI(mbz:, r.tid, s)
    ------------------------------------------------------------

    psi5_deleted_pivots AS (
        SELECT DISTINCT
            'mbz:' || d.tid AS subject_uri
        FROM deleted_TRACK d
    ),

    psi5_delta_plus AS (
        SELECT DISTINCT
            'mbz:' || i.tid AS s,
            'rdf:type'     AS p,
            'mo:Track'     AS o,
            psi5_uri        AS g
        FROM inserted_TRACK i
    ),

    psi5_payload AS (
        SELECT jsonb_build_object(
            'rule', 'Ψ5',
            'rule_uri', psi5_uri,
            'pivot_relation', 'Track',
            'type', 'pivot',
            'A_minus', '[]'::jsonb,
            'A_plus',  '[]'::jsonb,
            'deleted_pivot_uris',
                COALESCE(
                    (SELECT jsonb_agg(subject_uri) FROM psi5_deleted_pivots),
                    '[]'::jsonb
                ),
            'S2',
                '[]'::jsonb,
            'DeltaPlus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object('s', s, 'p', p, 'o', o, 'g', g)
                        )
                        FROM psi5_delta_plus
                    ),
                    '[]'::jsonb
                )
        ) AS payload
    ),

    ------------------------------------------------------------
    -- Ψ12: pivot-relevant rule
    -- Ψ12: dc:title(s,v) <- Track(r), hasURI(mbz:, r.tid, s),
    --       nonNull(r.name), RDFLiteral(r.name, "title", "Track", v)
    ------------------------------------------------------------

    psi12_deleted_pivots AS (
        SELECT DISTINCT
            'mbz:' || d.tid AS subject_uri
        FROM deleted_TRACK d
    ),

    psi12_delta_plus AS (
        SELECT DISTINCT
            'mbz:' || i.tid AS s,
            'dc:title'    AS p,
            i.name        AS o,
            psi12_uri     AS g
        FROM inserted_TRACK i
        WHERE i.name IS NOT NULL
    ),

    psi12_payload AS (
        SELECT jsonb_build_object(
            'rule', 'Ψ12',
            'rule_uri', psi12_uri,
            'pivot_relation', 'Track',
            'type', 'pivot',
            'A_minus', '[]'::jsonb,
            'A_plus',  '[]'::jsonb,
            'deleted_pivot_uris',
                COALESCE(
                    (SELECT jsonb_agg(subject_uri) FROM psi12_deleted_pivots),
                    '[]'::jsonb
                ),
            'S2',
                '[]'::jsonb,
            'DeltaPlus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object('s', s, 'p', p, 'o', o, 'g', g)
                        )
                        FROM psi12_delta_plus
                    ),
                    '[]'::jsonb
                )
        ) AS payload
    ),

    ------------------------------------------------------------
    -- Ψ7: relation-relevant rule
    -- Ψ7: foaf:made(s,g) <- Artist(r), hasURI(mbz:, r.gid, s),
    --       fk1(r,r1), fk2(r1,r2), fk3(r2,r3),
    --       Track(r3), hasURI(mbz:, r3.tid, g)
    --
    -- TRACK occurs once in path(Ψ7).
    -- Therefore A_minus[Ψ7](u) is computed using σ1 and D.
    ------------------------------------------------------------

    psi7_A_minus AS (
        SELECT DISTINCT
            a.aid,
            a.gid,
            'mbz:' || a.gid AS subject_uri
        FROM artist a
        JOIN artistcredit ac ON ac.aid = a.aid
        JOIN credit c        ON c.cid = ac.cid
        JOIN deleted_TRACK d ON d.cid = c.cid
    ),

    psi7_S2 AS (
        SELECT DISTINCT
            'mbz:' || a.gid AS s,
            'foaf:made'    AS p,
            'mbz:' || t.tid AS o,
            psi7_uri        AS g
        FROM psi7_A_minus a
        JOIN artistcredit ac ON ac.aid = a.aid
        JOIN credit c        ON c.cid = ac.cid
        JOIN track t         ON t.cid = c.cid
    ),

    psi7_A_plus AS (
        SELECT DISTINCT
            a.aid,
            a.gid,
            'mbz:' || a.gid AS subject_uri
        FROM artist a
        JOIN artistcredit ac  ON ac.aid = a.aid
        JOIN credit c         ON c.cid = ac.cid
        JOIN inserted_TRACK i ON i.cid = c.cid
    ),

    psi7_delta_plus AS (
        SELECT DISTINCT
            'mbz:' || a.gid AS s,
            'foaf:made'    AS p,
            'mbz:' || t.tid AS o,
            psi7_uri        AS g
        FROM psi7_A_plus a
        JOIN artistcredit ac ON ac.aid = a.aid
        JOIN credit c        ON c.cid = ac.cid
        JOIN track t         ON t.cid = c.cid
    ),

    psi7_payload AS (
        SELECT jsonb_build_object(
            'rule', 'Ψ7',
            'rule_uri', psi7_uri,
            'pivot_relation', 'Artist',
            'path', 'Artist --fk1--> ArtistCredit --fk2--> Credit --fk3--> Track',
            'type', 'relation',
            'A_minus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'aid', aid,
                                'gid', gid,
                                'subject_uri', subject_uri
                            )
                        )
                        FROM psi7_A_minus
                    ),
                    '[]'::jsonb
                ),
            'A_plus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'aid', aid,
                                'gid', gid,
                                'subject_uri', subject_uri
                            )
                        )
                        FROM psi7_A_plus
                    ),
                    '[]'::jsonb
                ),
            'deleted_pivot_uris',
                '[]'::jsonb,
            'S2',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object('s', s, 'p', p, 'o', o, 'g', g)
                        )
                        FROM psi7_S2
                    ),
                    '[]'::jsonb
                ),
            'DeltaPlus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object('s', s, 'p', p, 'o', o, 'g', g)
                        )
                        FROM psi7_delta_plus
                    ),
                    '[]'::jsonb
                )
        ) AS payload
    ),

    ------------------------------------------------------------
    -- Ψ8: relation-relevant rule
    -- Ψ8: mo:track(s,g) <- Medium(r), hasURI(mbz:, r.mid, s),
    --       fk4(r,f), Track(f), hasURI(mbz:, f.tid, g)
    --
    -- TRACK occurs once in path(Ψ8).
    -- Therefore A_minus[Ψ8](u) is computed using σ1 and D.
    ------------------------------------------------------------

    psi8_A_minus AS (
        SELECT DISTINCT
            m.mid,
            'mbz:' || m.mid AS subject_uri
        FROM medium m
        JOIN deleted_TRACK d ON d.mid = m.mid
    ),

    psi8_S2 AS (
        SELECT DISTINCT
            'mbz:' || m.mid AS s,
            'mo:track'     AS p,
            'mbz:' || t.tid AS o,
            psi8_uri        AS g
        FROM psi8_A_minus m
        JOIN track t ON t.mid = m.mid
    ),

    psi8_A_plus AS (
        SELECT DISTINCT
            m.mid,
            'mbz:' || m.mid AS subject_uri
        FROM medium m
        JOIN inserted_TRACK i ON i.mid = m.mid
    ),

    psi8_delta_plus AS (
        SELECT DISTINCT
            'mbz:' || m.mid AS s,
            'mo:track'     AS p,
            'mbz:' || t.tid AS o,
            psi8_uri        AS g
        FROM psi8_A_plus m
        JOIN track t ON t.mid = m.mid
    ),

    psi8_payload AS (
        SELECT jsonb_build_object(
            'rule', 'Ψ8',
            'rule_uri', psi8_uri,
            'pivot_relation', 'Medium',
            'path', 'Medium --fk4--> Track',
            'type', 'relation',
            'A_minus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'mid', mid,
                                'subject_uri', subject_uri
                            )
                        )
                        FROM psi8_A_minus
                    ),
                    '[]'::jsonb
                ),
            'A_plus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'mid', mid,
                                'subject_uri', subject_uri
                            )
                        )
                        FROM psi8_A_plus
                    ),
                    '[]'::jsonb
                ),
            'deleted_pivot_uris',
                '[]'::jsonb,
            'S2',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object('s', s, 'p', p, 'o', o, 'g', g)
                        )
                        FROM psi8_S2
                    ),
                    '[]'::jsonb
                ),
            'DeltaPlus',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object('s', s, 'p', p, 'o', o, 'g', g)
                        )
                        FROM psi8_delta_plus
                    ),
                    '[]'::jsonb
                )
        ) AS payload
    ),

    ------------------------------------------------------------
    -- Aggregate rule payloads
    ------------------------------------------------------------

    all_payloads AS (
        SELECT jsonb_agg(payload) AS rule_payloads
        FROM (
            SELECT payload FROM psi5_payload
            UNION ALL
            SELECT payload FROM psi12_payload
            UNION ALL
            SELECT payload FROM psi7_payload
            UNION ALL
            SELECT payload FROM psi8_payload
        ) x
    )

    SELECT rule_payloads
    INTO v_payload
    FROM all_payloads;

    ------------------------------------------------------------
    -- Store the logical maintenance event
    ------------------------------------------------------------

    INSERT INTO rdf_maintenance_queue (
        relation_name,
        operation_type,
        dataset_uri,
        sparql_endpoint,
        deleted_tuples,
        inserted_tuples,
        rule_payloads,
        status,
        created_at
    )
    VALUES (
        'TRACK',
        TG_OP,
        'https://ekg.example.org/views/musicbrainz-rdf',
        'https://ekg.example.org/views/musicbrainz-rdf/sparql',
        COALESCE((SELECT jsonb_agg(to_jsonb(d)) FROM deleted_TRACK d), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(to_jsonb(i)) FROM inserted_TRACK i), '[]'::jsonb),
        v_payload,
        'pending',
        now()
    )
    RETURNING event_id INTO v_event_id;

    RETURN NULL;
END;
$$;