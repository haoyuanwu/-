#!/usr/bin/env python3
"""Relay MCP stdio messages to the phone's authenticated LAN MCP endpoint."""
import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    endpoint = os.environ.get("REAREYES_MCP_URL", "")
    token = os.environ.get("REAREYES_MCP_TOKEN", "")
    url = urlsplit(endpoint)
    if url.scheme != "http" or not url.hostname or url.path != "/mcp" or not token:
        print("Set REAREYES_MCP_URL and REAREYES_MCP_TOKEN from Robot Eyes.", file=sys.stderr)
        return 2

    http = build_opener(ProxyHandler({}), NoRedirect())
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    for line in sys.stdin.buffer:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict):
            continue

        failure = None
        try:
            with http.open(Request(endpoint, data=line.rstrip(b"\r\n"), headers=headers), timeout=5) as response:
                if response.status != 202:
                    reply = json.load(response)
                    version = reply.get("result", {}).get("protocolVersion")
                    if message.get("method") == "initialize" and version:
                        headers["MCP-Protocol-Version"] = version
                    print(json.dumps(reply), flush=True)
        except HTTPError as error:
            failure = f"Robot Eyes returned HTTP {error.code}. Check the app, URL, and access key."
        except (ValueError, OSError, URLError):
            failure = "Robot Eyes MCP is unreachable or returned an invalid response."

        if failure and "id" in message:
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"],
                              "error": {"code": -32000, "message": failure}}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
