import collections.abc
import concurrent.futures
import contextlib
import importlib
import os
import sys
import threading
import types
import typing

THREADS: typing.Final = int(os.environ.get("ZYPY_TEST_THREADS", "8"))
ROUNDS: typing.Final = int(os.environ.get("ZYPY_TEST_ROUNDS", "2000"))


def extension() -> types.ModuleType:
    """Import the free-threaded test extension without enabling the GIL."""
    ext = importlib.import_module("zypy_tests")
    assert not sys._is_gil_enabled()
    return ext


def in_threads[T](work: collections.abc.Callable[[int], T]) -> list[T]:
    """Run `work` in synchronized threads, passing each thread's index and collecting the results."""
    barrier = threading.Barrier(THREADS)

    def start(index: int) -> T:
        """Wait for the other threads, then work."""
        barrier.wait()
        return work(index)

    with concurrent.futures.ThreadPoolExecutor(THREADS) as pool:
        return list(pool.map(start, range(THREADS)))


def counter_calls() -> None:
    """Check that instance locking preserves concurrent Counter increments."""
    counter = extension().Counter()

    def work(_index: int) -> None:
        """Count ROUNDS times."""
        for _ in range(ROUNDS):
            counter()

    in_threads(work)
    assert counter.count == THREADS * ROUNDS


def module_state() -> None:
    """Check that module locking preserves concurrent state updates."""
    ext = extension()
    start = ext.count_calls()

    def work(_index: int) -> None:
        """Count ROUNDS calls."""
        for _ in range(ROUNDS):
            ext.count_calls()

    in_threads(work)
    assert ext.count_calls() == start + THREADS * ROUNDS + 1


def bag_appends() -> None:
    """Check concurrent appends to a Bag backed by a Zig ArrayList."""
    bag = extension().Bag()

    def work(index: int) -> None:
        """Append the thread's index ROUNDS times."""
        for _ in range(ROUNDS):
            bag.append(index)

    in_threads(work)
    assert len(bag) == THREADS * ROUNDS
    assert bag.total() == ROUNDS * sum(range(THREADS))


def stack_appends_and_pops() -> None:
    """Check concurrent inherited appends and custom pops on a Zig subclass."""
    stack = extension().Stack()

    def work(index: int) -> int:
        """Append and pop items repeatedly, then return the number of items popped."""
        popped = 0
        for i in range(ROUNDS):
            stack.append(index)
            if i % 2:
                stack.pop()
                popped += 1

        return popped

    popped = sum(in_threads(work))
    assert len(stack) == THREADS * ROUNDS - popped


def field_writes() -> None:
    """Replace a py.Owned field in some threads while others read it."""
    node = extension().Node([0])

    def work(index: int) -> None:
        """Write the field in even threads, and read it in odd ones."""
        for i in range(ROUNDS):
            if index % 2:
                assert isinstance(node.value, list)
            else:
                node.value = [index, i]

    in_threads(work)


def property_writes() -> None:
    """Check concurrent field writes and reads through properties, methods, and instance copies."""
    ext = extension()
    shape = ext.Shape("square", 4)

    def work(index: int) -> None:
        """Set the label to new strings, or read it."""
        for i in range(ROUNDS):
            match index % 4:
                case 0:
                    shape.label = f"square{i % 10}"
                case 1:
                    assert shape.label.startswith("square")
                case 2:
                    assert shape.describe().endswith(" with 4 sides")
                case _:
                    assert ext.label_length(shape) in {6, 7}

    in_threads(work)


def container_reads() -> None:
    """Read strings from a list in some threads while others replace them with new ones."""
    ext = extension()
    words = [f"word{i:02}" for i in range(64)]

    def work(index: int) -> None:
        """Replace words in even threads, and add up their lengths in odd ones."""
        for i in range(ROUNDS):
            if index % 2:
                assert ext.total_length(words) == 6 * len(words)
            else:
                words[i % len(words)] = f"word{i % 100:02}"

    in_threads(work)


def pops() -> None:
    """Check that concurrent pops remove each list item exactly once."""
    ext = extension()
    count = THREADS * ROUNDS // 4
    items = list(range(count))

    def work(_index: int) -> list[int]:
        """Pop items until the list is empty."""
        popped: list[int] = []
        while True:
            try:
                popped.append(ext.pop_at(items, 0))
            except IndexError:
                return popped

    popped = [item for items in in_threads(work) for item in items]
    assert sorted(popped) == list(range(count))


def dict_iteration() -> None:
    """Check dict iteration during concurrent updates, including size-change errors."""
    ext = extension()
    values = dict.fromkeys(range(100), 1.0)

    def work(index: int) -> None:
        """Add and remove keys in even threads; sum values in odd threads."""
        for i in range(ROUNDS):
            if index % 2:
                with contextlib.suppress(RuntimeError):
                    assert isinstance(ext.sum_values(values), float)
            else:
                key = 100 + index * ROUNDS + i
                values[key] = 1.0
                del values[key]

    in_threads(work)
