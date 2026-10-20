import mixed._core

mean = mixed._core.mean


def variance(xs: list[float]) -> float:
    """Get the population variance of `xs`, using the Zig `mean`."""
    average = mean(xs)
    return mean([(x - average) ** 2 for x in xs])
