"""Paired-run ratio estimates with deterministic bootstrap intervals."""
import math
import random
import statistics


def quantile(values, probability):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(probability * len(ordered)) - 1)]


def ratio_interval(ratios):
    logs = [math.log(value) for value in ratios]
    randomizer = random.Random(20260916)
    means = [math.exp(statistics.mean(randomizer.choices(logs, k=len(logs)))) for _ in range(10000)]
    return {"estimate": math.exp(statistics.mean(logs)), "lower95": quantile(means, .025), "upper95": quantile(means, .975)}
