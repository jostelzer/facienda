#!/usr/bin/env python3
"""Export one Hindsight bank as JSON lines, for `facienda-mcp memory-import`.

Reads the embedded PostgreSQL instance Facienda's Hindsight service uses (~/.pg0/instances/<storage-id>) with its
bundled psql, read-only. Writes units, entities, unit_entities, cooccurrences, links and chunks into OUTPUT/.
Standard library only.

Before using the instance password the script checks that pg0's state is private, that the output directory
belongs to this account and is not group/world-writable, and that whatever listens on the PostgreSQL port
belongs to this account (otherwise another local user could squat the port and capture PGPASSWORD).
"""
import argparse
import json
import os
import subprocess
from pathlib import Path
import stat

from memory_service_credentials import private_directory, secure_pg0, valid_storage_id

TABLES = {
    "units": """SELECT id, document_id, chunk_id, fact_type, text, context, occurred_start, occurred_end, mentioned_at, event_date,
        embedding::text AS embedding, proof_count, source_memory_ids, consolidated_at, consolidation_failed_at, created_at, updated_at
        FROM memory_units WHERE bank_id = :'bank'""",
    "entities": """SELECT id, canonical_name, mention_count, first_seen, last_seen FROM entities
        WHERE bank_id = :'bank' AND COALESCE(entity_kind, 'regular') = 'regular'""",
    "unit_entities": """SELECT ue.unit_id, ue.entity_id FROM unit_entities ue JOIN memory_units u ON u.id = ue.unit_id
        WHERE u.bank_id = :'bank'""",
    "cooccurrences": """SELECT c.entity_id_1, c.entity_id_2, c.cooccurrence_count, c.last_cooccurred FROM entity_cooccurrences c
        JOIN entities e ON e.id = c.entity_id_1 WHERE e.bank_id = :'bank'""",
    "links": """SELECT from_unit_id, to_unit_id, link_type, weight FROM memory_links
        WHERE bank_id = :'bank' AND link_type IN ('temporal', 'semantic', 'caused_by')""",
    "chunks": """SELECT document_id, chunk_index, content_hash FROM chunks WHERE bank_id = :'bank'""",
}


def listener_owners(port):
    """Owning user IDs of the processes listening on a loopback TCP port, per lsof; empty if none are visible."""
    result = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{int(port)}", "-sTCP:LISTEN", "-Fu"], capture_output=True, text=True, timeout=15)
    return {int(line[1:]) for line in result.stdout.splitlines() if line.startswith("u") and line[1:].isdigit()}


def verify_listener(port):
    """Fail closed unless every listener on the port is ours. Processes lsof cannot see (other users') count as none."""
    owners = listener_owners(port)
    if not owners or owners != {os.getuid()}:
        raise SystemExit(f"Refusing to send the database password: port {port} is not served by a process owned by this account")


def write_private(path, text):
    """Create a new 0600 file without following symlinks or applying the umask-dependent default."""
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except FileExistsError:
        raise SystemExit(f"{path} already exists; remove it or choose another output directory") from None
    with os.fdopen(descriptor, "w") as stream:
        stream.write(text)


def read_instance(storage_id):
    path = Path.home() / ".pg0/instances" / storage_id / "instance.json"
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(descriptor) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise SystemExit("instance.json must be a private file owned by this account")
        return json.load(stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bank", required=True, help="Hindsight bank ID, e.g. facienda-<uuid> (the memory's bankId)")
    parser.add_argument("--storage-id", required=True, help="pg0 instance name the service runs, e.g. facienda-<uuid>")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    if not valid_storage_id(args.storage_id):
        parser.error("Invalid storage instance identifier")
    os.umask(0o077)
    try:
        secure_pg0(args.storage_id)
        instance = read_instance(args.storage_id)
        out = Path(args.output)
        # A new directory is 0700; an existing one (mkdir(mode=) does not apply to it) must be ours and not writable by others.
        private_directory(out, create=True, forbidden=0o022, repair=False)
    except (RuntimeError, OSError) as error:
        raise SystemExit(str(error)) from None
    psql = Path(instance["installation_dir"]) / instance["version"] / "bin/psql"
    verify_listener(instance["port"])
    env = dict(os.environ, PGPASSWORD=instance["password"], PGOPTIONS="-c default_transaction_read_only=on")
    for name, query in TABLES.items():
        sql = f"SELECT row_to_json(t) FROM ({' '.join(query.split())}) t;"
        result = subprocess.run([str(psql), "-h", "127.0.0.1", "-p", str(instance["port"]), "-U", instance["username"], "-d", instance["database"],
                                 "-v", f"bank={args.bank}", "-v", "ON_ERROR_STOP=1", "-At"], input=sql, env=env, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"{name}: {result.stderr.strip()}")
        write_private(out / f"{name}.jsonl", result.stdout)
        print(f"{name}: {result.stdout.count(chr(10))}")


if __name__ == "__main__":
    main()
