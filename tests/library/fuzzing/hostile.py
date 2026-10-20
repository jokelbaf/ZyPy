import collections.abc
import enum


class Hostile:
    """An object whose protocol methods raise."""

    def __index__(self) -> int:
        """Raise an error during integer conversion."""
        raise ValueError("no index")

    def __float__(self) -> float:
        """Raise an error during float conversion."""
        raise ValueError("no float")

    def __bool__(self) -> bool:
        """Raise an error during truth testing."""
        raise ValueError("no truth")

    def __len__(self) -> int:
        """Raise an error when asked for the length."""
        raise ValueError("no length")

    def __iter__(self) -> collections.abc.Iterator[object]:
        """Raise an error when iteration starts."""
        raise ValueError("no iterator")

    def __getitem__(self, key: object) -> object:
        """Raise an error during item lookup."""
        raise ValueError("no item")

    def __eq__(self, other: object) -> bool:
        """Raise an error during comparison."""
        raise ValueError("no equality")

    def __hash__(self) -> int:
        """Raise an error during hashing."""
        raise ValueError("no hash")

    def keys(self) -> list[str]:
        """Return matching struct field names so conversion proceeds to the failing lookups."""
        return ["name", "age", "value", "data", "owner"]


class Emptier:
    """An object that empties its container during numeric or boolean conversion."""

    def __init__(self, container: list[object] | dict[object, object] | set[object]) -> None:
        """Remember the container to empty."""
        self.container = container

    def __index__(self) -> int:
        """Empty the container and return 1."""
        self.container.clear()
        return 1

    def __float__(self) -> float:
        """Empty the container and return 1.0."""
        self.container.clear()
        return 1.0

    def __bool__(self) -> bool:
        """Empty the container and return True."""
        self.container.clear()
        return True


class HugeLength:
    """A three-item sequence that reports a length larger than Py_ssize_t can hold."""

    def __len__(self) -> int:
        """Report a length larger than Py_ssize_t can hold."""
        return 2**62

    def __getitem__(self, index: int) -> int:
        """Return the index."""
        if index >= 3:
            raise IndexError(index)

        return index


class Integer(int):
    """A subclass of int."""


class Float(float):
    """A subclass of float."""


class Text(str):
    """A subclass of str."""


class Data(bytes):
    """A subclass of bytes."""


class Items(list[object]):
    """A subclass of list."""


class Row(tuple[object, ...]):
    """A subclass of tuple."""


class Table(dict[object, object]):
    """A subclass of dict that makes up values for missing keys."""

    def __missing__(self, key: object) -> object:
        """Return a value for a missing key without storing it."""
        return 0


class Color(enum.Enum):
    """A Python enum with the same member names as the test extension's enums."""

    red = 1
    low = 2
    north = 3


def emptying_list(item: object) -> list[object]:
    """Make a list whose second item empties it when converted."""
    items: list[object] = [item]
    items.append(Emptier(items))
    items.append(item)
    return items


def emptying_dict(value: object) -> dict[object, object]:
    """Make a dict whose values empty it when converted."""
    entries: dict[object, object] = {"name": value}
    entries["age"] = Emptier(entries)
    entries["value"] = Emptier(entries)
    return entries


def emptying_set() -> set[object]:
    """Make a set with an item that empties it when converted."""
    items: set[object] = {1, 2}
    items.add(Emptier(items))
    return items
