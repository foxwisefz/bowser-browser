import Foundation
let toolCatalogJSON = #"""
[
  {
    "name": "website_layout",
    "description": "Compose a tree of live website views in the selected browser window. get returns same-window tabs, visible panes, active tab, and tree with current divider weights. create_tab opens a background http(s) page and returns created ID. set applies tree atomically: nest row/column containers with webview leaves, relative weights, minimum sizes and per-container resizable dividers. reset retains all tabs and shows the active page. IDs must be unique and belong to this window/profile. Structural budget: 16 levels, 256 total nodes. No saved apps. Runtime changes are not file Undo; durable mods provide apply/reset controls using Surface.layout and Layout builders.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "enum": [
            "get",
            "create_tab",
            "set",
            "reset"
          ]
        },
        "url": {
          "type": "string",
          "description": "Required for create_tab: http(s) URL."
        },
        "tree": {
          "$ref": "#/$defs/node",
          "description": "Required for set. A container tree or a single webview leaf."
        }
      },
      "required": [
        "action"
      ],
      "additionalProperties": false,
      "$defs": {
        "node": {
          "oneOf": [
            {
              "type": "object",
              "properties": {
                "type": {
                  "const": "webview"
                },
                "webview": {
                  "type": "integer",
                  "minimum": 1
                },
                "weight": {
                  "type": "number",
                  "exclusiveMinimum": 0,
                  "description": "Relative size within the parent; default 1."
                },
                "min_width": {
                  "type": "number",
                  "minimum": 0,
                  "description": "Minimum width in window points; default 0."
                },
                "min_height": {
                  "type": "number",
                  "minimum": 0,
                  "description": "Minimum height in window points; default 0."
                }
              },
              "required": [
                "type",
                "webview"
              ],
              "additionalProperties": false
            },
            {
              "type": "object",
              "properties": {
                "type": {
                  "enum": [
                    "row",
                    "column"
                  ]
                },
                "children": {
                  "type": "array",
                  "minItems": 1,
                  "items": {
                    "$ref": "#/$defs/node"
                  }
                },
                "resizable": {
                  "type": "boolean",
                  "default": true
                },
                "weight": {
                  "type": "number",
                  "exclusiveMinimum": 0,
                  "description": "Relative size within the parent; default 1."
                },
                "min_width": {
                  "type": "number",
                  "minimum": 0,
                  "description": "Minimum width in window points; default 0."
                },
                "min_height": {
                  "type": "number",
                  "minimum": 0,
                  "description": "Minimum height in window points; default 0."
                }
              },
              "required": [
                "type",
                "children"
              ],
              "additionalProperties": false
            }
          ]
        }
      }
    }
  },
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
    "description": "Install or update an Elixir mod draft during an active ModSmith run, recording Undo history. New files belong to the selected browser profile; an existing file owned by another profile cannot be overwritten. Untagged mods belong to Default. Returns compilation and startup/reload results; fix errors, then verify runtime behavior. Use shell_theme for native theme state. Not available for saved apps. Reference the installed file by path in the final envelope; omit unchanged content.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Filename only, e.g. og_aol.ex"
        },
        "content": {
          "type": "string",
          "description": "Elixir source with a direct use BowserBrain.Mod in a top-level defmodule. For site scope, every mod must directly declare the matching literal host; quoted examples do not count. This validation is not an execution sandbox. Use the ModSmith guide for BowserBrain.View builders and native renderer availability. Compose View.state scopes with independent editor, preview, selector, switch, flow and action nodes. command maps (set/toggle/wrap/insert/select/undo/redo/snapshot/submit/reset/discard) target the nearest scope. Actions choose icons/styles/layout; the editor has no bundled toolbar. Private data stays in native state/events, never page scripts. Native View.palette/2,3 scopes semantic colors and light/dark maps with optional high_contrast_light/high_contrast_dark. Native toolbar style also accepts palette and adaptive foreground/background/border/accent. Prefer adaptive colors; fixed hex stays fixed. Side toolbar widths are 16..800 points. profile_avatar(id, badge: true, size: 18) adds a circular backing; its native renderer must support badge. No remote avatar assets are fetched."
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
    "description": "Existing mods and site payloads (restricted to the selected profile during ModSmith): path, on/off, host scope, one line on what it does. Check this BEFORE writing anything \u2014 modify what exists instead of duplicating it.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "read_mod",
    "description": "Full source of one existing mod or payload by catalog path (mods/<name>.ex or sites/<host>/<name>.css|.js). Disabled (.off) files are found by their plain name too. In ModSmith, each read is restricted to the run profile.",
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
    "description": "Read a mod's durable Store (BowserBrain.Store): mod = the defmodule name; omit key for everything it stored. In ModSmith, the module must have an unambiguous declaration owned by the run profile.",
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
    "description": "Write one key into a mod's durable Store \u2014 SEED state (e.g. a follow with a 4-day-old timestamp) to verify time-based behavior now. value is any JSON. In ModSmith, ownership is checked on every call; another profile's mod data is unavailable.",
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
