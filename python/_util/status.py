class ServerStatusHolder:
    _client_visible_status: list[str]

    def __init__(self, initial_status: str):
        self._client_visible_status = [initial_status]

    def set(self, status: str):
        print("ServerStatus.set(): " + status)
        self._client_visible_status[-1] = status

    def get(self) -> str:
        return self._client_visible_status[-1]

    def push(self, status: str):
        print("ServerStatus.push(): " + status)
        self._client_visible_status.append(status)

    def pop(self):
        print(f"ServerStatus.pop() -> {self.get()}")
        self._client_visible_status.pop()


class StatusContext:
    new_status: str
    status_holder: ServerStatusHolder | None

    def __init__(self, new_status: str, status_holder: ServerStatusHolder | None):
        self.new_status = new_status
        self.status_holder = status_holder

    def __enter__(self) -> ServerStatusHolder | None:
        if self.status_holder is not None:
            self.status_holder.push(self.new_status)

        return self.status_holder

    def __exit__(self, exc_type, exc_value, tb):
        if self.status_holder is not None:
            self.status_holder.pop()
