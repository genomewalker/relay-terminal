#!/usr/bin/env python3
"""Validate the static site; publication remains an explicit, gated operation."""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
from urllib.parse import urlsplit, unquote

ROOT = Path(__file__).resolve().parents[1] / "website"


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.links, self.images, self.metas = set(), [], [], {}
        self.scripts = 0

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            require(attrs["id"] not in self.ids, "duplicate element id")
            self.ids.add(attrs["id"])
        if tag in ("a", "link") and "href" in attrs:
            self.links.append(attrs["href"])
        if tag == "img":
            require("alt" in attrs, "image without alternative text")
            require("width" in attrs and "height" in attrs, "image without dimensions")
            self.images.append(attrs["src"])
        if tag == "meta":
            self.metas[attrs.get("name")] = attrs.get("content", "")
        if tag == "script":
            self.scripts += 1


def validate(production=False):
    gate = json.loads((ROOT / "release-gate.json").read_text())
    require(gate["domain"] == "relay.vaklab.dev", "Unexpected domain")
    page = Page()
    html = (ROOT / "index.html").read_text()
    page.feed(html)
    require(page.scripts == 0, "draft does not need JavaScript")
    require("viewport" in page.metas and 'lang="en"' in html, "Missing viewport or language")
    for link in page.links + page.images:
        parsed = urlsplit(link)
        if parsed.scheme:
            require(parsed.scheme == "https", "external URL must use HTTPS")
            continue
        require(not parsed.netloc, "protocol-relative external URL")
        if parsed.path:
            target = (ROOT / unquote(parsed.path)).resolve()
            require(target.is_relative_to(ROOT.resolve()) and target.is_file(), link)
        elif parsed.fragment:
            require(parsed.fragment in page.ids, link)
    if production:
        require(gate["productionReady"] is True, "Production acceptance has not passed")
        for field in ("appVersion", "appCommit", "downloadURL", "notarizationStatus", "acceptanceRecord"):
            require(gate.get(field), f"Missing production evidence: {field}")
        require(gate["downloadURL"].startswith("https://github.com/genomewalker/relay-terminal/releases/download/"), "Unexpected release download host")
        require("noindex" not in page.metas.get("robots", ""), "Production page is noindex")
    else:
        require(gate["productionReady"] is False, "Use --production for a release candidate")
        require("noindex" in page.metas.get("robots", ""), "Preview must be noindex")
        require(not (ROOT / "CNAME").exists(), "Do not configure the domain before acceptance")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    try:
        validate(args.production)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"Website validation failed: {error}\n")
    print("Website validation passed (" + ("production" if args.production else "development preview") + ")")


if __name__ == "__main__":
    main()
