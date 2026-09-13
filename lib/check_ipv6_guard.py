"""Verify the complete dedicated IPv6 OUTPUT ruleset, including loopback."""
import json
import sys


def matches(data, table):
    objects = data["nftables"]
    tables = [obj["table"] for obj in objects if "table" in obj]
    chains = [obj["chain"] for obj in objects if "chain" in obj]
    rules = [obj["rule"] for obj in objects if "rule" in obj]
    if len(tables) != 1 or len(chains) != 1 or len(rules) != 1:
        return False
    if tables[0].get("family") != "ip6" or tables[0].get("name") != table or tables[0].get("flags"):
        return False
    expected_chain = dict(family="ip6", table=table, name="output", type="filter",
                          hook="output", prio=0, policy="accept")
    if any(chains[0].get(key) != value for key, value in expected_chain.items()):
        return False
    rule = rules[0]
    if (rule.get("family"), rule.get("table"), rule.get("chain")) != ("ip6", table, "output"):
        return False
    expressions = [expr for expr in rule["expr"] if set(expr) != {"counter"}]
    # Numeric nft JSON represents ICMPv6 administratively prohibited as code 1.
    for expression in expressions:
        reject = expression.get("reject", {})
        if reject.get("type") == "icmpv6" and reject.get("expr") == 1:
            reject["expr"] = "admin-prohibited"
    return expressions == [
        {"match": {"op": "!=", "left": {"meta": {"key": "oifname"}}, "right": "lo"}},
        {"reject": {"type": "icmpv6", "expr": "admin-prohibited"}},
    ]


if __name__ == "__main__":
    try:
        sys.exit(0 if matches(json.load(sys.stdin), sys.argv[1]) else 1)
    except (ValueError, KeyError, TypeError, AttributeError):
        sys.exit(2)
