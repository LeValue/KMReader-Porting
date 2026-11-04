"""Catalog metadata only; opaque PDOC identifiers and Unicode remain intact."""

import time

from defusedxml import ElementTree as ET
from defusedxml.common import DefusedXmlException

from .client import CATALOG_URL
from .common import KindleError


def local_name(element):
    return element.tag.rsplit("}", 1)[-1]


def value(element, name):
    child = next((e for e in element if local_name(e) == name), None)
    return "".join(child.itertext()).strip() if child is not None else ""


def parse_catalog(raw, *, limit):
    try:
        root = ET.fromstring(raw)
    except (ET.ParseError, DefusedXmlException):
        raise KindleError(
            "catalog_xml", "Catalogo Amazon non riconosciuto.", stage="catalog"
        ) from None
    response = (
        root
        if local_name(root) == "response"
        else next((e for e in root if local_name(e) == "response"), None)
    )
    if response is None or not any(
        local_name(e) == "add_update_list" for e in response
    ):
        raise KindleError(
            "catalog_shape",
            "La risposta non contiene un catalogo verificabile.",
            stage="catalog",
        )
    items = {}
    for group in response:
        if local_name(group) != "add_update_list":
            continue
        for element in group:
            if local_name(element) != "meta_data":
                continue
            identifier, kind = value(element, "ASIN"), value(element, "cde_contenttype")
            if not identifier or kind not in ("EBOK", "PDOC"):
                continue
            key = kind + ":" + identifier
            items[key] = {
                "key": key,
                "id": identifier,
                "type": kind,
                "title": value(element, "title") or identifier,
                "authors": [
                    "".join(e.itertext()).strip()
                    for e in element.iter()
                    if local_name(e) == "author" and "".join(e.itertext()).strip()
                ],
                "revision": value(element, "content_version")
                or value(element, "version"),
                "publication_date": value(element, "publication_date"),
            }
    removed = []
    for group in response:
        if local_name(group) in ("delete_list", "remove_list"):
            for element in group:
                identifier = value(element, "ASIN") or (element.text or "").strip()
                kind = value(element, "cde_contenttype")
                if identifier:
                    removed.append({"id": identifier, "type": kind})
    paging = {local_name(e): (e.text or "").strip() for e in response}
    # Do not reinterpret sync_time as a pagination cursor. Until an actual
    # paginated response is verified, expose uncertainty rather than lose titles.
    more = any(
        paging.get(k, "").lower() not in ("", "false", "0", "no")
        for k in (
            "has_more",
            "has_more_items",
            "more",
            "truncated",
            "next_token",
            "next_page_token",
        )
    )
    count = sum(1 for e in response.iter() if local_name(e) == "meta_data")
    return {
        "items": list(items.values()),
        "removed": removed,
        "sync_time": value(response, "sync_time"),
        "complete": not more and count < limit,
    }


def synchronize(client, previous=None, *, full=False, limit=10000):
    previous = previous or {}
    incremental = bool(
        previous.get("complete") and previous.get("sync_time") and not full
    )
    params = {"item_count": limit}
    if incremental:
        params["last_sync_time"] = previous["sync_time"]
    raw = client.bounded_get(CATALOG_URL, stage="catalog", params=params)
    current = parse_catalog(raw, limit=limit)
    items = (
        {item["key"]: item for item in previous.get("items", [])} if incremental else {}
    )
    for removed in current["removed"]:
        items = {
            k: item
            for k, item in items.items()
            if not (
                item["id"] == removed["id"]
                and (not removed["type"] or item["type"] == removed["type"])
            )
        }
    items.update({item["key"]: item for item in current["items"]})
    return {
        "schema": 1,
        "marketplace": "amazon.it",
        "fetched_at": int(time.time()),
        "sync_time": current["sync_time"],
        "complete": current["complete"],
        "items": sorted(
            items.values(), key=lambda item: (item["title"].casefold(), item["key"])
        ),
    }
