import sqlite3
import sys
from typing import TypeVar, Iterator, Iterable

# Generated with `sqlite3 data/requests-history.db .schema`
table_script = """\
CREATE TABLE IF NOT EXISTS "ProviderRecords" (
	identifiers VARCHAR NOT NULL, 
	created_at DATETIME NOT NULL, 
	machine_info JSON, 
	human_info VARCHAR, 
	PRIMARY KEY (identifiers, created_at), 
	CONSTRAINT "all columns" UNIQUE (identifiers, machine_info)
);
CREATE TABLE IF NOT EXISTS "InferenceModelRecords" (
	id INTEGER NOT NULL, 
	human_id VARCHAR NOT NULL, 
	first_seen_at DATETIME, 
	last_seen DATETIME, 
	provider_identifiers VARCHAR NOT NULL, 
	model_identifiers JSON, 
	combined_inference_parameters JSON, 
	PRIMARY KEY (id), 
	CONSTRAINT "all columns" UNIQUE (human_id, provider_identifiers, model_identifiers, combined_inference_parameters)
);
CREATE TABLE IF NOT EXISTS "InferenceEvents" (
	id INTEGER NOT NULL, 
	model_record_id INTEGER NOT NULL, 
	prompt_tokens INTEGER, 
	prompt_eval_time DOUBLE, 
	prompt_with_templating VARCHAR, 
	response_created_at DATETIME NOT NULL, 
	response_tokens INTEGER, 
	response_eval_time DOUBLE, 
	response_error VARCHAR, 
	response_info JSON, 
	parent_sequence INTEGER, 
	reason VARCHAR, 
	PRIMARY KEY (id), 
	CONSTRAINT "stats columns" UNIQUE (model_record_id, prompt_tokens, prompt_eval_time, prompt_with_templating, response_created_at, response_tokens, response_eval_time, response_error, response_info)
);
CREATE TABLE IF NOT EXISTS "ChatMessages" (
	"id"	INTEGER NOT NULL,
	"role"	VARCHAR NOT NULL,
	"content"	VARCHAR NOT NULL,
	"created_at"	DATETIME,
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "ChatSequences" (
	"id"	INTEGER NOT NULL,
	"human_desc"	VARCHAR,
	"user_pinned"	BOOLEAN,
	"current_message"	INTEGER NOT NULL,
	"parent_sequence"	INTEGER,
	"generated_at"	DATETIME,
	"generation_complete"	BOOLEAN,
	"inference_job_id"	INTEGER,
	"inference_error"	VARCHAR,
	PRIMARY KEY("id")
);
"""

T = TypeVar("T")


def maybe_tqdm(it: Iterable[T], desc) -> Iterator[T] | Iterable[T]:
    try:
        import tqdm
        return tqdm.tqdm(it, desc=desc, ncols=100, delay=0)
    except ImportError:
        return it


def _lookup_one_message(
        dst_conn: sqlite3.Connection,
        src_conn: sqlite3.Connection,
        src_key: tuple,
        r: sqlite3.Row,  # source database's info
) -> int:
    # Check if this row already exists in the destination
    dst_cursor = dst_conn.execute(
        "SELECT id FROM ChatMessages WHERE role IS ? AND content IS ? AND created_at IS ?",
        (r['role'], r['content'], r['created_at'],),
    )
    existing_dst_message = dst_cursor.fetchone()
    if existing_dst_message is not None:
        return existing_dst_message[0]

    else:
        src_cursor = src_conn.execute("""
            SELECT role, content, created_at FROM ChatMessages WHERE id IS ?
        """, src_key)
        message_info = src_cursor.fetchone()

        # NB We re-insert the ChatMessage row just in case;
        # we don't necessarily want every ChatMessage merged in.
        dst_conn.execute(
            "INSERT OR IGNORE INTO ChatMessages(role, content, created_at) "
            "VALUES(?,?,?)",
            message_info,
        )
        dst_cursor = dst_conn.execute(
            "SELECT id FROM ChatMessages WHERE role IS ? AND content IS ? AND created_at IS ?",
            (r['role'], r['content'], r['created_at'],),
        )
        new_current_message = dst_cursor.fetchone()[0]

    return new_current_message


current_message_cache = {}


def merge_one_message(
        dst_conn: sqlite3.Connection,
        src_conn: sqlite3.Connection,
        src_key: tuple,
        r: sqlite3.Row,  # source database's info
):
    if src_key in current_message_cache:
        return current_message_cache[src_key]
    else:
        result = _lookup_one_message(dst_conn, src_conn, src_key, r)
        print(f"\r\033[K[TRACE] Merged ChatMessage {r['id']: >4_} => {result: >4_}")
        current_message_cache[src_key] = result
        return result


def merge_all_messages(
        dst_conn: sqlite3.Connection,
        src_conn: sqlite3.Connection,
        limit_str: str,
) -> None:
    message_rows = src_conn.execute(
        "SELECT * FROM ChatMessages "
        f"{limit_str}"
    )
    for r in maybe_tqdm(message_rows.fetchall(), "all messages"):
        merge_one_message(dst_conn, src_conn, (r['id'],), r)


def merge_others(
        dst_conn: sqlite3.Connection,
        src_conn: sqlite3.Connection,
        limit_str: str,
) -> None:
    current_message_cache = {}

    sequence_rows = src_conn.execute(f"""
        SELECT ChatSequences.id, ChatSequences.current_message,
            ChatMessages.role, ChatMessages.content, ChatMessages.created_at
        FROM ChatSequences
        INNER JOIN ChatMessages ON ChatMessages.id=ChatSequences.current_message
        {limit_str}
    """)
    for r in maybe_tqdm(sequence_rows.fetchall(), "sequences"):
        new_current_message = merge_one_message(dst_conn, src_conn, (r['current_message'],), r)


if __name__ == '__main__':
    dst_conn = sqlite3.connect(sys.argv[1])
    with dst_conn:
        # Construct the basic database schema for the new file.
        dst_cursor: sqlite3.Cursor
        dst_conn.cursor().executescript(table_script)
        dst_conn.cursor().execute(
            "PRAGMA journal_mode=wal;"
        )

        for db_in_filename in sys.argv[2:]:
            src_conn = sqlite3.connect(db_in_filename)
            src_conn.row_factory = sqlite3.Row

            with src_conn:
                print(f"file: {db_in_filename}")
                merge_all_messages(dst_conn, src_conn, "LIMIT 2")
                merge_others(dst_conn, src_conn, "LIMIT 5")

        print(f"done merging into {sys.argv[1]}")
