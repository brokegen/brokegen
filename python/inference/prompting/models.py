from pydantic import BaseModel


class ChatMessage(BaseModel):
    pass

    # TODO: These are actually JSON fields, how would Pydantic work?
    # role: RoleName
    # content: PromptText
