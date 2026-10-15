#!/usr/bin/env python3
"""Add one release to Sparkle's appcast, newest first, with its Markdown notes shown as HTML in the update dialog."""
import argparse
import html
import os
import re
from email.utils import formatdate
from xml.etree import ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def notes_html(markdown):
    """Paragraphs and "- " lists are enough for release notes."""
    parts, items = [], []
    for line in markdown.splitlines() + [""]:
        line = line.strip()
        if line.startswith(("- ", "* ")):
            items.append(f"<li>{inline(line[2:])}</li>")
            continue
        if items:
            parts.append("<ul>" + "".join(items) + "</ul>")
            items = []
        if line.startswith("#"):
            parts.append(f"<h3>{inline(line.lstrip('#').strip())}</h3>")
        elif line:
            parts.append(f"<p>{inline(line)}</p>")
    return "".join(parts)


def inline(text):
    text = html.escape(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)


def main():
    parser = argparse.ArgumentParser()
    for flag in ("appcast", "version", "build", "url", "signature", "notes", "minimum-system"):
        parser.add_argument(f"--{flag}", required=True)
    args = parser.parse_args()
    if os.path.exists(args.appcast):
        tree = ET.parse(args.appcast)
        channel = tree.getroot().find("channel")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Facienda"
        tree = ET.ElementTree(root)
    for item in channel.findall("item"):
        if item.findtext(f"{{{SPARKLE}}}shortVersionString") == args.version:
            raise SystemExit(f"Version {args.version} is already in the appcast.")
    # sign_update prints: sparkle:edSignature="…" length="…"
    attributes = dict(re.findall(r'(sparkle:edSignature|length)="([^"]+)"', args.signature))
    if len(attributes) != 2:
        raise SystemExit(f"Unexpected sign_update output: {args.signature}")
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Facienda {args.version}"
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = args.minimum_system
    with open(args.notes, encoding="utf-8") as notes:
        ET.SubElement(item, "description").text = notes_html(notes.read())
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "type": "application/octet-stream",
        "length": attributes["length"],
        f"{{{SPARKLE}}}edSignature": attributes["sparkle:edSignature"],
    })
    position = list(channel).index(channel.find("item")) if channel.find("item") is not None else len(channel)
    channel.insert(position, item)
    ET.indent(tree)
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
