class ServerStatusHolder:
    _client_visible_status: list[str]

    def __init__(self, initial_status: str):
        self._client_visible_status = [initial_status]

    def set(self, status: str):
        self._client_visible_status.append(status)

    def get(self) -> str:
        return self._client_visible_status[-1]

    def push(self, status: str):
        self._client_visible_status.append(status)

    def pop(self):
        self._client_visible_status.pop()
