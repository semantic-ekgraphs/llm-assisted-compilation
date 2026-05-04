import os
import time
import requests
import psycopg2
from dotenv import load_dotenv

load_dotenv()

PG_CONFIG = {
    "host": os.getenv("PG_HOST"),
    "port": os.getenv("PG_PORT"),
    "dbname": os.getenv("PG_DBNAME"),
    "user": os.getenv("PG_USER"),
    "password": os.getenv("PG_PASSWORD"),
}

SPARQL_ENDPOINT = os.getenv("GRAPHDB_QUERY_ENDPOINT")
SPARQL_UPDATE_ENDPOINT = os.getenv("GRAPHDB_UPDATE_ENDPOINT")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "2"))


def get_connection():
    return psycopg2.connect(**PG_CONFIG)


def fetch_next_event(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT event_id, rule_payloads
            FROM rdf_maintenance_queue
            WHERE status = 'pending'
            ORDER BY event_id
            LIMIT 1
            FOR UPDATE SKIP LOCKED
        """)
        return cur.fetchone()


def mark_processing(conn, event_id):
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE rdf_maintenance_queue
            SET status = 'processing'
            WHERE event_id = %s
        """, (event_id,))


def mark_done(conn, event_id):
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE rdf_maintenance_queue
            SET status = 'done',
                processed_at = now()
            WHERE event_id = %s
        """, (event_id,))


def mark_error(conn, event_id, error):
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE rdf_maintenance_queue
            SET status = 'error',
                error_message = %s
            WHERE event_id = %s
        """, (str(error), event_id))


def normalize_uri(value: str) -> str:
    if value.startswith("mbz:"):
        return value.replace("mbz:", "http://musicbrainz.org/")
    if value == "rdf:type":
        return "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    if value == "mo:Track":
        return "http://purl.org/ontology/mo/Track"
    if value == "mo:track":
        return "http://purl.org/ontology/mo/track"
    if value == "foaf:made":
        return "http://xmlns.com/foaf/0.1/made"
    if value == "dc:title":
        return "http://purl.org/dc/elements/1.1/title"
    return value


def normalize_quad(q: dict) -> tuple:
    return (
        normalize_uri(q["s"]),
        normalize_uri(q["p"]),
        normalize_uri(q["o"]) if isinstance(q["o"], str) else q["o"],
        normalize_uri(q["g"]),
    )


def sparql_term(value):
    value = normalize_uri(value)

    if isinstance(value, str) and (
        value.startswith("http://") or value.startswith("https://")
    ):
        return f"<{value}>"

    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def get_affected_subjects(rule):
    if rule["type"] == "pivot":
        return rule.get("deleted_pivot_uris", [])

    if rule["type"] == "relation":
        return [
            item["subject_uri"]
            for item in rule.get("A_minus", [])
            if "subject_uri" in item
        ]

    return []


def query_graphdb_for_old_quads(graph_uri, subjects):
    if not subjects:
        return []

    values = " ".join(
        f"<{normalize_uri(subject)}>"
        for subject in subjects
    )

    query = f"""
    SELECT ?s ?p ?o
    WHERE {{
      GRAPH <{graph_uri}> {{
        VALUES ?s {{ {values} }}
        ?s ?p ?o .
      }}
    }}
    """

    response = requests.post(
        SPARQL_ENDPOINT,
        data={"query": query},
        headers={"Accept": "application/sparql-results+json"},
        timeout=30,
    )
    response.raise_for_status()

    data = response.json()
    quads = []

    for row in data.get("results", {}).get("bindings", []):
        quads.append({
            "s": row["s"]["value"],
            "p": row["p"]["value"],
            "o": row["o"]["value"],
            "g": graph_uri,
        })

    return quads


def apply_delete_to_graphdb(quads):
    if not quads:
        print("Nenhum quad para remover.")
        return

    blocks = []

    for q in quads:
        blocks.append(
            f"GRAPH {sparql_term(q['g'])} {{ "
            f"{sparql_term(q['s'])} "
            f"{sparql_term(q['p'])} "
            f"{sparql_term(q['o'])} . }}"
        )

    update = "DELETE DATA {\n" + "\n".join(blocks) + "\n}"

    response = requests.post(
        SPARQL_UPDATE_ENDPOINT,
        data=update.encode("utf-8"),
        headers={"Content-Type": "application/sparql-update"},
        timeout=30,
    )
    response.raise_for_status()


def apply_insert_to_graphdb(quads):
    if not quads:
        print("Nenhum quad para inserir.")
        return

    blocks = []

    for q in quads:
        blocks.append(
            f"GRAPH {sparql_term(q['g'])} {{ "
            f"{sparql_term(q['s'])} "
            f"{sparql_term(q['p'])} "
            f"{sparql_term(q['o'])} . }}"
        )

    update = "INSERT DATA {\n" + "\n".join(blocks) + "\n}"

    response = requests.post(
        SPARQL_UPDATE_ENDPOINT,
        data=update.encode("utf-8"),
        headers={"Content-Type": "application/sparql-update"},
        timeout=30,
    )
    response.raise_for_status()


def compute_delta_minus(rule_payloads):
    delta_minus = []

    for rule in rule_payloads:
        rule_uri = rule["rule_uri"]
        rule_type = rule["type"]
        affected_subjects = get_affected_subjects(rule)

        if not affected_subjects:
            continue

        s1 = query_graphdb_for_old_quads(rule_uri, affected_subjects)

        if rule_type == "pivot":
            contribution = s1

        elif rule_type == "relation":
            s2 = rule.get("S2", [])
            s2_set = {normalize_quad(q) for q in s2}

            contribution = [
                q for q in s1
                if normalize_quad(q) not in s2_set
            ]

        else:
            contribution = []

        delta_minus.extend(contribution)

    return delta_minus


def compute_delta_plus(rule_payloads):
    delta_plus = []

    for rule in rule_payloads:
        for q in rule.get("DeltaPlus", []):
            delta_plus.append({
                "s": normalize_uri(q["s"]),
                "p": normalize_uri(q["p"]),
                "o": normalize_uri(q["o"]) if isinstance(q["o"], str) else q["o"],
                "g": normalize_uri(q["g"]),
            })

    return delta_plus


def process_event(event_id, rule_payloads):
    delta_minus = compute_delta_minus(rule_payloads)
    apply_delete_to_graphdb(delta_minus)

    delta_plus = compute_delta_plus(rule_payloads)
    apply_insert_to_graphdb(delta_plus)

    print(
        f"Evento {event_id}: "
        f"Δ− removido = {len(delta_minus)} quad(s), "
        f"Δ+ inserido = {len(delta_plus)} quad(s)."
    )


def run_worker():
    print("Worker iniciado...")
    print(f"GraphDB query endpoint: {SPARQL_ENDPOINT}")
    print(f"GraphDB update endpoint: {SPARQL_UPDATE_ENDPOINT}")

    while True:
        event_id = None

        try:
            with get_connection() as conn:
                event = fetch_next_event(conn)

                if event is None:
                    conn.commit()
                    time.sleep(POLL_INTERVAL)
                    continue

                event_id, rule_payloads = event

                mark_processing(conn, event_id)
                conn.commit()

                process_event(event_id, rule_payloads)

                mark_done(conn, event_id)
                conn.commit()

        except Exception as e:
            print("Erro:", e)

            if event_id is not None:
                with get_connection() as conn:
                    mark_error(conn, event_id, e)
                    conn.commit()

            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    run_worker()