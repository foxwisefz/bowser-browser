import Foundation
let toolCatalogJSON = #"""
[
  {
    "name": "native_screenshot",
    "description": "Capture the selected visible browser window including native toolbars. Returns an image and window id; coordinates are points from top-left. Requires macOS screen capture permission; errors are not visual verification.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "native_click",
    "description": "Click a native browser control using coordinates and window id from the latest screenshot. Website content is excluded. Screenshot again to verify the result; dispatch alone does not prove success.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "x": {
          "type": "number"
        },
        "y": {
          "type": "number"
        },
        "window": {
          "type": "integer"
        }
      },
      "required": [
        "x",
        "y",
        "window"
      ]
    }
  },
  {
    "name": "put_asset",
    "description": "Save self-contained SVG source in this mod's owned assets with Undo history. Returns image_path for View.image(path: image_path, size: 48). No external references or scripts; max 200KB. Reference installed relative path in final files.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string"
        },
        "content": {
          "type": "string"
        }
      },
      "required": [
        "name",
        "content"
      ]
    }
  },
  {
    "name": "toolbars",
    "description": "Read effective native edge toolbar definitions recorded by the brain. Confirms state, not rendered pixels.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "put_mod",
    "description": "Install or update an Elixir mod draft during an active ModSmith run, recording Undo history. Returns compilation and startup/reload results; fix errors, then verify runtime behavior. Use shell_theme for native theme state. Not available for saved apps. Reference the installed file by path in the final envelope; omit unchanged content.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Filename only, e.g. og_aol.ex"
        },
        "content": {
          "type": "string",
          "description": "Elixir source. Use the ModSmith guide for BowserBrain.View builders and native renderer availability. profile_avatar(id, badge: true, size: 18) adds a circular backing; its native renderer must support badge. No remote avatar assets are fetched."
        }
      },
      "required": [
        "name",
        "content"
      ]
    }
  },
  {
    "name": "shell_theme",
    "description": "Read the effective native browser theme recorded by the brain. Empty means native defaults. This confirms theme state, not visual rendering.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "list_tabs",
    "description": "List open tabs (webview id + url) and which is active.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "page_eval",
    "description": "Evaluate JavaScript in a tab and return the result. webview 0 = first tab; use list_tabs ids to target.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "js": {
          "type": "string"
        },
        "webview": {
          "type": "integer"
        }
      },
      "required": [
        "js"
      ]
    }
  },
  {
    "name": "page_html",
    "description": "outerHTML of the first element matching a CSS selector (truncated at 20kB). Ground truth for what's really in the DOM.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "selector": {
          "type": "string"
        },
        "webview": {
          "type": "integer"
        }
      },
      "required": [
        "selector"
      ]
    }
  },
  {
    "name": "put_payload",
    "description": "Install (or overwrite) a persistent site payload at sites/<host>/<name>.css|.js \u2014 applies within ~1s after a page reload. Use to TEST a draft live, then verify with page_eval.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "host": {
          "type": "string"
        },
        "name": {
          "type": "string"
        },
        "content": {
          "type": "string"
        }
      },
      "required": [
        "host",
        "name",
        "content"
      ]
    }
  },
  {
    "name": "list_mods",
    "description": "Every existing mod and site payload the owner already has: path, on/off, host scope, one line on what it does. Check this BEFORE writing anything \u2014 modify what exists instead of duplicating it.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "read_mod",
    "description": "Full source of one existing mod or payload by catalog path (mods/<name>.ex or sites/<host>/<name>.css|.js). Disabled (.off) files are found by their plain name too.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string"
        }
      },
      "required": [
        "path"
      ]
    }
  },
  {
    "name": "store_get",
    "description": "Read a mod's durable Store (BowserBrain.Store): mod = the defmodule name; omit key for everything it stored.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "mod": {
          "type": "string"
        },
        "key": {
          "type": "string"
        }
      },
      "required": [
        "mod"
      ]
    }
  },
  {
    "name": "store_put",
    "description": "Write one key into a mod's durable Store \u2014 SEED state (e.g. a follow with a 4-day-old timestamp) to verify time-based behavior now. value is any JSON.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "mod": {
          "type": "string"
        },
        "key": {
          "type": "string"
        },
        "value": {}
      },
      "required": [
        "mod",
        "key",
        "value"
      ]
    }
  }
]
"""#
