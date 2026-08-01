# Is this name free? — a domain search over RDAP.
#
#     python3 tools/domain_search.py lumen
#     python3 tools/domain_search.py lumen --tlds dev,io,sh,ai --suffixes lang,hq
#     python3 tools/domain_search.py lumen luma lumina --exact --json
#
# RDAP and not WHOIS, and that is the whole reason this is worth writing rather
# than typing names into a registrar: WHOIS is a text format that differs per
# registry and is rate-limited into uselessness, while RDAP is JSON with one
# meaning for "no such domain" — HTTP 404. So "available" here is a registry
# saying it has no record, not a page saying it has something to sell you.
#
# What this cannot tell you, and nobody's checker can:
#   * whether the name is TRADEMARKED. A free domain on a taken mark is a
#     rename waiting to happen. Search the register before you buy.
#   * whether it is PREMIUM. Plenty of short names are unregistered and priced
#     at four figures; RDAP says "available" for those exactly as it does for
#     a five-dollar one.
#   * whether a registry supports RDAP at all. A few ccTLDs do not, and this
#     says UNKNOWN rather than guessing — see `--dns-fallback`.
import argparse
import json
import socket
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# The bootstrap that redirects to whichever registry actually answers for a
# TLD. One host to know instead of a table to maintain.
RDAP = "https://rdap.org/domain/"

# Defaults chosen for a developer-tools brand: the two everyone wants, the two
# that read as infrastructure, the two that read as language/tooling, and .com
# because a name that cannot hold its .com eventually pays for it in support
# email from people who typed it.
TLDS = ["com", "dev", "io", "sh", "ai", "app", "org", "net", "tools", "run"]

# Affixes that keep a one-word name pronounceable. Deliberately short: a name
# you have to spell over a call is a name you rename later.
SUFFIXES = ["hq", "lang", "labs", "run", "dev", "kit", "stack"]
PREFIXES = ["get", "use", "try"]

AVAILABLE, TAKEN, UNKNOWN = "available", "taken", "unknown"

# Which TLDs have an RDAP service at all, from IANA's own bootstrap file.
#
# This lookup is not a nicety, it is the correctness of the whole tool. rdap.org
# answers 404 for a name that is free AND for a name under a TLD it cannot route
# — the two are indistinguishable from the status line. First run of this script
# reported `lumen.io` as available; it resolves to 4.68.54.34, which is Level 3,
# which is Lumen Technologies. .io publishes no RDAP, so every .io name looked
# free. A checker that says "available" about a domain owned by a company with
# your intended name is worse than no checker.
BOOTSTRAP = "https://data.iana.org/rdap/dns.json"

# Registries that answer RDAP despite not being in the bootstrap.
EXTRA_RDAP = {
    "sh": "https://rdap.identitydigital.services/rdap/domain/",
    "io": "https://rdap.identitydigital.services/rdap/domain/",
    "ac": "https://rdap.identitydigital.services/rdap/domain/",
}
_rdap_tlds = None


def rdap_tlds(timeout):
    global _rdap_tlds
    if _rdap_tlds is None:
        try:
            with urllib.request.urlopen(BOOTSTRAP, timeout=timeout) as r:
                doc = json.loads(r.read().decode())
            _rdap_tlds = {t for entry in doc.get("services", []) for t in entry[0]}
        except Exception:
            _rdap_tlds = set()  # empty means "cannot tell" — everything goes UNKNOWN
    return _rdap_tlds


def rdap_status(domain, timeout):
    """What the registry says about one domain.

    404 is the answer we are shopping for. 200 means registered. Anything else
    — a registry with no RDAP, a redirect loop, a timeout — is UNKNOWN and says
    so, because a checker that reports a broken lookup as "available" will
    eventually have someone buy nothing.
    """
    tld = domain.rsplit(".", 1)[-1]
    served = rdap_tlds(timeout)
    base = RDAP
    if served and tld not in served:
        # Not in IANA's bootstrap — but absence there does not mean the
        # registry has no RDAP, only that it never registered one. Identity
        # Digital operates .sh, .io and .ac and answers RDAP for them at its
        # own address; found by asking it about lumen.sh (200) after the
        # bootstrap said the TLD was dark. Without this, every .sh and .io
        # name is UNKNOWN, which for this project's naming search was most of
        # the interesting namespace.
        if tld in EXTRA_RDAP:
            base = EXTRA_RDAP[tld]
        else:
            # Truly no RDAP anywhere we know: a 404 below would mean "cannot
            # route", not "not registered". Refuse to guess.
            return UNKNOWN, "no rdap for ." + tld

    req = urllib.request.Request(base + domain, headers={
        "accept": "application/rdap+json",
        "user-agent": "domain-search/1.0 (+one-off naming check)",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return TAKEN if r.status == 200 else UNKNOWN, ""
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return AVAILABLE, ""
        if e.code == 429:
            # rdap.org throttles a burst, and a rate-limited answer is not an
            # answer — reporting it as UNKNOWN turned a 66-name search into 39
            # shrugs. Wait out the window it names (or a default) and ask once
            # more; only a second 429 is worth telling the reader about.
            wait = e.headers.get("retry-after") if e.headers else None
            try:
                pause = min(float(wait), 30.0) if wait else 4.0
            except ValueError:
                pause = 4.0
            time.sleep(pause)
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return (TAKEN if r.status == 200 else UNKNOWN), ""
            except urllib.error.HTTPError as e2:
                if e2.code == 404:
                    return AVAILABLE, ""
                return UNKNOWN, f"rate limited ({e2.code})"
            except Exception as e2:
                return UNKNOWN, type(e2).__name__
        return UNKNOWN, f"http {e.code}"
    except Exception as e:
        return UNKNOWN, type(e).__name__


def dns_taken(domain):
    """A weaker second opinion for a TLD with no RDAP.

    Resolvable means somebody owns it. NOT resolvable means very little — a
    registered domain with no records looks exactly like a free one from here
    — so this only ever downgrades UNKNOWN to TAKEN, and never promotes
    anything to AVAILABLE."""
    try:
        socket.getaddrinfo(domain, None)
        return True
    except socket.gaierror:
        return False
    except Exception:
        return False


def candidates(words, tlds, prefixes, suffixes, exact):
    """Every name to check, in the order a person would consider them: the bare
    word first, then affixed, so the output reads best-first without sorting."""
    seen, out = set(), []
    for w in words:
        stems = [w]
        if not exact:
            stems += [w + s for s in suffixes] + [p + w for p in prefixes]
        for stem in stems:
            for tld in tlds:
                d = f"{stem}.{tld}"
                if d not in seen:
                    seen.add(d)
                    out.append(d)
    return out


def main():
    p = argparse.ArgumentParser(description="Check domain availability over RDAP.")
    p.add_argument("words", nargs="+", help="the name(s) to check, without a TLD")
    p.add_argument("--tlds", default=",".join(TLDS))
    p.add_argument("--suffixes", default=",".join(SUFFIXES))
    p.add_argument("--prefixes", default=",".join(PREFIXES))
    p.add_argument("--exact", action="store_true", help="the bare words only, no affixes")
    p.add_argument("--dns-fallback", action="store_true",
                   help="for UNKNOWN results, let a successful DNS lookup call it taken")
    p.add_argument("--all", action="store_true", help="print taken ones too")
    p.add_argument("--json", action="store_true")
    p.add_argument("--workers", type=int, default=4,
                   help="rdap.org throttles per IP; 4 finishes a 60-name sweep without 429s")
    p.add_argument("--timeout", type=float, default=12.0)
    args = p.parse_args()

    names = candidates(
        args.words,
        [t.strip().lstrip(".") for t in args.tlds.split(",") if t.strip()],
        [x.strip() for x in args.prefixes.split(",") if x.strip()],
        [x.strip() for x in args.suffixes.split(",") if x.strip()],
        args.exact,
    )

    def check(d):
        status, note = rdap_status(d, args.timeout)
        if status == UNKNOWN and args.dns_fallback and dns_taken(d):
            status, note = TAKEN, "dns"
        return {"domain": d, "status": status, "note": note}

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(check, names))

    if args.json:
        print(json.dumps(rows, indent=1))
        return

    free = [r for r in rows if r["status"] == AVAILABLE]
    unknown = [r for r in rows if r["status"] == UNKNOWN]
    taken = [r for r in rows if r["status"] == TAKEN]

    print(f"checked {len(rows)} — {len(free)} available, {len(taken)} taken, {len(unknown)} unknown\n")
    if free:
        print("AVAILABLE")
        for r in free:
            print("  " + r["domain"])
    if unknown:
        print("\nUNKNOWN  (registry did not answer; check by hand)")
        for r in unknown:
            print(f"  {r['domain']:28} {r['note']}")
    if taken and args.all:
        print("\nTAKEN")
        for r in taken:
            print("  " + r["domain"])

    if free:
        print("\nBefore buying: search the trademark register, and price the name at a"
              "\nregistrar — RDAP cannot see a mark, and says nothing about premium pricing.")


if __name__ == "__main__":
    main()
