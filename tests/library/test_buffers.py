import array
import re
import types

import pytest


def test_buffers(ext: types.ModuleType) -> None:
    """Check buffer views of bytes, bytearray, memoryview, and array.array."""
    assert ext.buf_sum(array.array("d", [1, 2, 3])) == 6
    assert ext.buf_sum(memoryview(array.array("d", [0.5, 0.5]))) == 1
    assert ext.buf_sum(array.array("d")) == 0

    a = array.array("d", [1, 2])
    assert ext.scale(a, 10) is a
    assert a.tolist() == [10, 20]

    b = bytearray(3)
    ext.fill(b, 7)
    assert b == b"\x07\x07\x07"

    assert ext.first_byte(b"\x05") == 5
    assert ext.first_byte(b"") is None
    assert ext.shape(b"abc") == (1, 3)

    with pytest.raises(TypeError, match="expected a buffer of f64"):
        ext.buf_sum(array.array("f", [1]))

    with pytest.raises(BufferError):
        ext.scale(b"read-only", 1)


def test_buffers_are_released(ext: types.ModuleType) -> None:
    """Check that buffer views are released by resizing the source arrays."""
    a = array.array("d", [1, 2])
    ext.buf_sum(a)
    ext.buf_sum_and_release(a)

    with pytest.raises(TypeError):
        ext.dot(a, "not a buffer")

    ext.scale(a, 1)
    ext.first_byte(a)
    a.append(3)


def test_strided_buffers(ext: types.ModuleType) -> None:
    """Check strided buffers with non-contiguous memoryview slices."""
    numbers = memoryview(array.array("d", range(10)))
    assert ext.strided_sum(numbers[::2]) == 20
    assert ext.strided_order(numbers[::-3]) == [9, 6, 3, 0]
    assert ext.strided_order(numbers[5:5]) == []

    grid = memoryview(array.array("d", range(12))).cast("B").cast("d", [3, 4])
    assert ext.strided_at(grid, 1, 2) == 6
    assert ext.strided_order(grid[::2]) == [0, 1, 2, 3, 8, 9, 10, 11]
    assert ext.strided_at(grid[::-1], 0, 1) == 9
    assert ext.strided_layout(memoryview(bytes(range(12))).cast("B", [3, 4])) == (12, [3, 4], [4, 1])

    values = array.array("d", range(6))
    ext.strided_scale(memoryview(values)[1::2], 10)
    assert values.tolist() == [0, 10, 2, 30, 4, 50]

    values.append(6)


def test_strided_buffer_errors(ext: types.ModuleType) -> None:
    """Check invalid indexes, formats, and writes for strided buffers."""
    numbers = memoryview(array.array("d", range(10)))
    grid = memoryview(array.array("d", range(12))).cast("B").cast("d", [3, 4])

    with pytest.raises(IndexError, match=r"^buffer index out of range$"):
        ext.strided_at(grid, 3, 0)

    with pytest.raises(ValueError, match=r"^expected an index per dimension of the buffer \(1\), got 2$"):
        ext.strided_at(numbers, 0, 0)

    with pytest.raises(ValueError, match=r"^expected an index per dimension of the buffer \(1\), got 0$"):
        ext.scalar_value(numbers)

    with pytest.raises(TypeError, match="expected a buffer of f64"):
        ext.strided_sum(memoryview(b"ab"))

    with pytest.raises(BufferError):
        ext.strided_scale(memoryview(bytes(8)).cast("d"), 2)

    with pytest.raises(BufferError):
        ext.buf_sum(numbers[::2])

    with pytest.raises(TypeError, match=r"expected a buffer of u8, got format 'd' \(item size 8\)"):
        ext.strided_layout(memoryview(array.array("d", [1, 2])))


def test_buffers_are_released_with_their_layout(ext: types.ModuleType) -> None:
    """Check that buffer dimensions and strides remain valid during release."""
    assert ext.byte_sum(ext.raw_exporter()) == 10
    assert ext.raw_released() == (4, 1)

    assert ext.strided_layout(ext.raw_exporter()) == (4, [4], [1])
    assert ext.raw_released() == (4, 1)


def test_strided_numpy_arrays(ext: types.ModuleType) -> None:
    """Check strided buffers with NumPy slices and transposed arrays."""
    numpy = pytest.importorskip("numpy")
    grid = numpy.arange(12.0).reshape(3, 4)

    assert ext.strided_sum(grid[:, ::2]) == grid[:, ::2].sum()
    assert ext.strided_order(grid.T) == grid.T.flatten().tolist()
    assert ext.strided_at(grid[:, ::2], 1, 1) == 6
    assert ext.scalar_value(numpy.float64(2.5)) == 2.5

    ext.strided_scale(grid[::2, 1:], -1)
    assert grid.tolist() == [[0, -1, -2, -3], [4, 5, 6, 7], [8, -9, -10, -11]]


@pytest.mark.parametrize(
    ("flaw", "contiguous", "strided"),
    [
        ("negative_dimensions", "buffer has -1 dimensions (expected 0 to 64)", None),
        ("too_many_dimensions", "buffer has 65 dimensions (expected 0 to 64)", None),
        ("zero_item_size", "buffer item size must be positive, not 0", None),
        ("no_shape", "buffer has no shape", None),
        ("negative_size", "buffer dimension 0 has negative size -4", None),
        ("huge_shape", "buffer is too large", None),
        ("wrong_length", "buffer length 24 doesn't match its shape and item size (32 bytes)", None),
        ("no_memory", "buffer has no memory", None),
        ("not_contiguous", "buffer is not C-contiguous", 4),
        ("overflowing_strides", "buffer is not C-contiguous", "buffer offsets overflow"),
        ("negative_strides", "buffer is not C-contiguous", "buffer offsets overflow"),
        ("suboffsets", "buffer has suboffsets, which weren't requested", None),
    ],
)
def test_malformed_buffers(ext: types.ModuleType, flaw: str, contiguous: str, strided: str | int | None) -> None:
    """Check errors for invalid buffer layouts and cleanup of acquired views."""
    exporter = ext.malformed_exporter(flaw)

    with pytest.raises(BufferError, match=f"^{re.escape(contiguous)}$"):
        ext.buf_sum(exporter)

    if isinstance(strided, int):
        assert ext.strided_sum(exporter) == strided
    else:
        with pytest.raises(BufferError, match=f"^{re.escape(strided or contiguous)}$"):
            ext.strided_sum(exporter)

    assert ext.malformed_outstanding() == 0


def test_read_only_exporters(ext: types.ModuleType) -> None:
    """Check valid exporter layouts and rejection of read-only data by writable views."""
    exporter = ext.malformed_exporter("read_only")
    assert ext.buf_sum(exporter) == 10
    assert ext.strided_sum(exporter) == 10

    with pytest.raises(BufferError, match=r"^buffer is read-only$"):
        ext.scale(exporter, 2)

    with pytest.raises(BufferError, match=r"^buffer is read-only$"):
        ext.strided_scale(exporter, 2)

    assert ext.malformed_outstanding() == 0


def test_bool_buffers(ext: types.ModuleType) -> None:
    """Check that buffer bools contain only 0 or 1."""
    flags = memoryview(bytearray(b"\x00\x01\x01\x00\x01")).cast("?")
    assert ext.true_count(flags) == ext.strided_true_count(flags) == 3
    assert ext.strided_true_count(flags[::-2]) == 2

    other = memoryview(bytearray(b"\x00\x02\x01")).cast("?")
    for count in (ext.true_count, ext.strided_true_count):
        with pytest.raises(ValueError, match=r"^expected a buffer of bools, got the byte 2$"):
            count(other)

    assert ext.strided_true_count(other[::2]) == 1


@pytest.mark.parametrize("length", [1, 64, 4097])
def test_bool_buffers_are_checked_everywhere(ext: types.ModuleType, length: int) -> None:
    """Check rejection of invalid bool bytes throughout a buffer."""
    data = bytearray(b"\x01" * length)
    assert ext.true_count(memoryview(data).cast("?")) == length

    for position in {0, length // 2, length - 1}:
        invalid = data[:position] + b"\x07" + b"\xff" * (length - position - 1)
        with pytest.raises(ValueError, match=r"got the byte 7$"):
            ext.true_count(memoryview(invalid).cast("?"))
