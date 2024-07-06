from typing import Iterator, AsyncIterator

import pytest

from inference.iterators import to_async, consolidate_and_call, consolidate_and_yield


@pytest.mark.asyncio
async def test_sync_to_async():
    iter0: Iterator[int] = iter([0, 1, 2])
    iter1: AsyncIterator[int] = to_async(iter0)

    n_out = [n async for n in iter1]
    assert n_out == [0, 1, 2]


@pytest.mark.asyncio
async def test_ccall():
    iter0: AsyncIterator[int] = to_async(iter([0, 1, 2]))

    result: list[int] = []
    result_checked: bool = False

    def consolidate(new, result):
        result.append(new)
        return result

    async def checker(result):
        assert result == [0, 1, 2]

        nonlocal result_checked
        result_checked = True

    iter1: AsyncIterator[int] = consolidate_and_call(
        iter0, consolidate, result, checker
    )

    result2 = [chunk async for chunk in iter1]
    assert result2 == [0, 1, 2]

    assert result_checked


@pytest.mark.asyncio
async def test_cyield():
    iter0: AsyncIterator[int] = to_async(iter([0, 1, 2]))

    result = []

    def consolidate(new, result):
        result.append(new)
        return result

    async def yielder(_):
        yield 3
        yield 4

    iter1: AsyncIterator[int] = consolidate_and_yield(
        iter0, consolidate, result, yielder
    )

    result2 = [chunk async for chunk in iter1]
    assert result2 == [0, 1, 2, 3, 4]


@pytest.mark.asyncio
async def test_before_after():
    iter0: AsyncIterator[int] = to_async(iter([0, 1, 2]))

    result = []
    before_checked: bool = False
    after_checked: bool = True

    def consolidate(new, result):
        result.append(new)
        return result

    async def before(primordial: AsyncIterator[int]) -> AsyncIterator[int]:
        nonlocal before_checked
        before_checked = True

        async for chunk in primordial:
            yield chunk

    async def after(result):
        assert result == [0, 1, 2]

        nonlocal after_checked
        after_checked = True

    iter1: AsyncIterator[int] = before(iter0)
    iter2: AsyncIterator[int] = consolidate_and_call(
        iter1, consolidate, result, after,
    )

    assert await anext(iter2) == 0
    assert before_checked

    result2 = [chunk async for chunk in iter1]
    assert result2 == [1, 2]

    assert after_checked
