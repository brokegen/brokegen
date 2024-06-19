async def _log_inference_event(response_content_json):
    nonlocal inference_model
    inference_model = history_db.merge(inference_model)

    inference_job = InferenceEventOrm(
        model_record_id=inference_model.id,
        reason="chat sequence",
        response_error="[haven't received/finalized response info yet]",
    )

    finalize_inference_job(inference_job, response_content_json)
    history_db.add(inference_job)
    history_db.commit()

    assistant_response = ChatMessageOrm(
        role="assistant",
        content=safe_get(response_content_json, "message", "content"),
        created_at=inference_job.response_created_at,
    )
    history_db.add(assistant_response)
    history_db.commit()

    # Add what we need for response_sequence
    original_sequence.user_pinned = False
    response_sequence.user_pinned = True

    history_db.add(original_sequence)
    history_db.add(response_sequence)

    response_sequence.current_message = assistant_response.id

    response_sequence.generated_at = inference_job.response_created_at
    response_sequence.generation_complete = response_content_json["done"]
    response_sequence.inference_job_id = inference_job.id
    if inference_job.response_error:
        response_sequence.inference_error = inference_job.response_error

    history_db.add(response_sequence)
    history_db.commit()

    # And complete the circular reference that really should be handled in the SQLAlchemy ORM
    inference_job = history_db.merge(inference_job)
    inference_job.parent_sequence = response_sequence.id

    # TODO: This is disabled while we figure out why the duplicate InferenceEvent never commits its response content
    if False and not inference_job.response_error:
        inference_job.response_error = (
            "this is a duplicate InferenceEvent, because do_generate_raw_templated will dump its own raws in. "
            "we're keeping this one because it's tied into the actual ChatSequence."
        )

    history_db.add(inference_job)
    history_db.commit()

    return {
        "new_sequence_id": response_sequence.id,
        "done": True,
    }
