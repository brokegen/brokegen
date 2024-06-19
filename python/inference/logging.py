from _util.json import JSONDict
from providers.inference_models.database import HistoryDB


async def inference_event_logger(
        consolidated_response: JSONDict,
        history_db: HistoryDB,
):
    pass


async def construct_new_sequence_from(
        consolidated_response: JSONDict,
        history_db: HistoryDB,
):
    pass
