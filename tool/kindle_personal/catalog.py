"""Catalog metadata only; opaque PDOC identifiers and Unicode remain intact."""

import time
import re

from defusedxml import ElementTree as ET
from defusedxml.common import DefusedXmlException

from .client import CATALOG_URL
from .common import KindleError

CLASSIFICATION_VERSION = 1


def _dictionary_flags(element, kind):
    tags = set()
    for group in element:
        if local_name(group) == "content_tags":
            for part in group.iter():
                tags.update(re.split(r"[\s,;|]+", (part.text or "").strip().upper()))
    tags.intersection_update({"DICT", "FREE_DICT"})
    dictionary = bool(tags) or any(
        value(element, key).lower() in ("true", "1")
        for key in ("is_dictionary", "isDictionary")
    )
    purchased = any(
        local_name(e) == "origin" and value(e, "type").casefold() == "purchase"
        for e in element.iter()
    )
    bundled = kind == "EBOK" and dictionary and ("FREE_DICT" in tags or not purchased)
    return {
        "content_tags": sorted(tags),
        "is_dictionary": dictionary,
        "is_amazon_dictionary": bundled,
    }


def visible_items(snapshot, *, include_dictionaries=False):
    return [
        item
        for item in snapshot.get("items", [])
        if include_dictionaries or not item.get("is_amazon_dictionary", False)
    ]


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
                **_dictionary_flags(element, kind),
            }
    removed = []
    for group in response:
        if local_name(group) in ("delete_list", "remove_list", "removal_list"):
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
    count = sum(
        1
        for group in response
        if local_name(group) == "add_update_list"
        for e in group
        if local_name(e) == "meta_data"
    )
    return {
        "items": list(items.values()),
        "removed": removed,
        "sync_time": value(response, "sync_time"),
        "complete": not more and count < limit,
        "classification_version": CLASSIFICATION_VERSION,
        "full_response": response.attrib.get("syncType", "").casefold() == "full",
    }


def synchronize(client, previous=None, *, full=False, limit=10000):
    previous = previous or {}
    incremental = bool(
        previous.get("complete")
        and previous.get("sync_time")
        and not full
        and previous.get("classification_version") == CLASSIFICATION_VERSION
    )
    params = {"item_count": limit}
    if incremental:
        params["last_sync_time"] = previous["sync_time"]
    raw = client.bounded_get(CATALOG_URL, stage="catalog", params=params)
    current = parse_catalog(raw, limit=limit)
    items = (
        {item["key"]: item for item in previous.get("items", [])}
        if incremental and not current["full_response"]
        else {}
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
        "schema": 2,
        "classification_version": CLASSIFICATION_VERSION,
        "marketplace": "amazon.it",
        "fetched_at": int(time.time()),
        "sync_time": current["sync_time"],
        "complete": current["complete"],
        "items": sorted(
            items.values(), key=lambda item: (item["title"].casefold(), item["key"])
        ),
    }
