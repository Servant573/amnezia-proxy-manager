"""Check exact destination coverage independently using integer intervals."""
import ipaddress
from pathlib import Path
import random
import runpy
import subprocess
import sys
import unittest


HELPER = Path(__file__).resolve().parents[1] / "lib/collapse_routes.py"
collapse_routes = runpy.run_path(str(HELPER))["collapse_routes"]


def coverage(networks):
    intervals = sorted((int(net.network_address), int(net.broadcast_address))
                       for net in networks)
    merged = []
    for start, end in intervals:
        if merged and start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


class CollapseTests(unittest.TestCase):
    def check_routes(self, source, expected):
        self.assertEqual([str(net) for net in collapse_routes(source)], expected)

    def test_adjacent_hosts_and_subnets(self):
        self.check_routes([f"192.0.2.{i}/32" for i in range(4)], ["192.0.2.0/30"])
        self.check_routes(["192.0.2.0/25", "192.0.2.128/25"], ["192.0.2.0/24"])

    def test_overlap_duplicates_and_host_bits(self):
        self.check_routes(["192.0.2.7/24", "192.0.2.7", "192.0.2.128/25",
                           "192.0.2.0/24"], ["192.0.2.0/24"])

    def test_sparse_hosts_do_not_widen(self):
        self.check_routes(["192.0.2.7", "192.0.2.200"],
                          ["192.0.2.7/32", "192.0.2.200/32"])
        self.check_routes(["192.0.2.1", "192.0.2.2"],
                          ["192.0.2.1/32", "192.0.2.2/32"])

    def test_default_and_address_boundaries(self):
        self.check_routes(["0.0.0.0/1", "128.0.0.0/1"], ["0.0.0.0/0"])
        self.check_routes(["192.0.2.7", "1.2.3.4/0"], ["0.0.0.0/0"])
        self.check_routes(["0.0.0.0", "255.255.255.255"],
                          ["0.0.0.0/32", "255.255.255.255/32"])

    def test_randomized_exact_coverage(self):
        rng = random.Random(271828)
        for _ in range(150):
            source = [f"{ipaddress.IPv4Address(rng.getrandbits(32))}/{rng.randrange(8, 33)}"
                      for _ in range(100)]
            # Include dense runs, gaps, duplicates and overlapping subnets.
            source += [f"192.0.2.{rng.randrange(256)}/32" for _ in range(300)]
            source += source[:20]
            networks = [ipaddress.IPv4Network(line, strict=False) for line in source]
            result = list(collapse_routes(source))
            self.assertEqual(coverage(networks), coverage(result))
            self.assertLessEqual(len(result), len(set(networks)))
            self.assertEqual(result, list(collapse_routes(map(str, result))))

    def test_invalid_input_has_no_partial_output(self):
        for source in ("", "192.0.2.1\ninvalid\n", "::1/128\n"):
            result = subprocess.run([sys.executable, str(HELPER)], input=source,
                                    text=True, capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
