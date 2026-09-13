"""Verify the entire small nft table, not just the existence of its name."""
import json
import socket
import sys


def matches(data, table, uid, host, port, index):
    objects = data["nftables"]
    tables = [obj["table"] for obj in objects if "table" in obj]
    chains = [obj["chain"] for obj in objects if "chain" in obj]
    rules = [obj["rule"] for obj in objects if "rule" in obj]
    if len(tables) != 1 or len(chains) != 1 or len(rules) != 1:
        return False
    if tables[0].get("family") != "inet" or tables[0].get("name") != table:
        return False
    if tables[0].get("flags"):
        return False
    chain = chains[0]
    expected = dict(family="inet", table=table, name="output", type="filter",
                    hook="output", prio=0, policy="accept")
    if any(chain.get(key) != value for key, value in expected.items()):
        return False
    rule = rules[0]
    if (rule.get("family"), rule.get("table"), rule.get("chain")) != ("inet", table, "output"):
        return False
    expected_expr = [
        {"match": {"op": "==", "left": {"meta": {"key": "skuid"}}, "right": int(uid)}},
        {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "daddr"}}, "right": host}},
        {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": int(port)}},
        {"match": {"op": "!=", "left": {"meta": {"key": "oif"}}, "right": int(index)}},
        {"drop": None},
    ]
    expressions = [expr for expr in rule["expr"] if set(expr) != {"counter"}]
    # nft 1.0.x emits an existing oif index as its name even in numeric JSON.
    # Resolve only an index-typed `oif`, never an `oifname` expression.
    for expr in expressions:
        match = expr.get("match", {})
        if match.get("left") == {"meta": {"key": "oif"}} and isinstance(match.get("right"), str):
            match["right"] = socket.if_nametoindex(match["right"])
    return expressions == expected_expr


if __name__ == "__main__":
    try:
        sys.exit(0 if matches(json.load(sys.stdin), *sys.argv[1:]) else 1)
    except (ValueError, KeyError, TypeError, AttributeError, OSError):
        sys.exit(2)
