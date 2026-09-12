defmodule BowserBrain.UserContentTest do
  use ExUnit.Case, async: true
  alias BowserBrain.UserContent

  test "replacing and clearing one owner retains other owners and content kinds" do
    state = %{scripts: %{}, styles: %{}}

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, ["old"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:b, "work"}, ["keep"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :styles, {:a, "work"}, ["css"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, ["replacement"], false}, nil, state)

    assert state.scripts == %{{:a, "work"} => ["replacement"], {:b, "work"} => ["keep"]}

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, [], false}, nil, state)

    assert state.scripts == %{{:b, "work"} => ["keep"]}
    assert state.styles == %{{:a, "work"} => ["css"]}
  end
  test "scoped styles replace independently of scripts and clear on host changes" do
    key = {:owner, "work"}
    scoped = {{:scoped_styles, :owner}, "work"}
    state = %{scripts: %{key => ["keep JS"]}, styles: %{key => ["old global CSS"]}}
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, ["body{}"], "one.test", false}, nil, state)
    assert state.scripts[key] == ["keep JS"]
    assert [%{host: "one.test", world: "isolated"}] = state.scripts[scoped]
    refute Map.has_key?(state.styles, key)
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, ["p{}"], "two.test", false}, nil, state)
    assert [%{host: "two.test"}] = state.scripts[scoped]
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, ["global{}"], nil, false}, nil, state)
    refute Map.has_key?(state.scripts, scoped)
    assert state.styles[key] == ["global{}"]
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, [], nil, false}, nil, state)
    assert state.styles == %{}
    assert state.scripts == %{key => ["keep JS"]}
  end

  @tag skip: if(System.find_executable("node"), do: false, else: "Node.js is required to execute the preservation script")
  test "preservation deletes field snapshots without reading them and only saves scroll" do
    harness = ~S"""
    const assert = require('node:assert/strict');
    const vm = require('node:vm');
    const now = Date.now();
    const scrollKey = 'bowser-scroll:example.com/page';
    const reads = [];
    function storage(initial) {
      const values = new Map(Object.entries(initial));
      return {
        values,
        get length() { return values.size; },
        key(i) { return [...values.keys()][i]; },
        getItem(key) {
          reads.push(key);
          assert.ok(!key.startsWith('bowser-preserve:'), 'must not read saved fields');
          return values.get(key) || null;
        },
        setItem(key, value) { values.set(key, value); },
        removeItem(key) { values.delete(key); }
      };
    }
    const local = storage({
      'bowser-preserve:example.com/page': '{"f":{"token":"sensitive"},"y":90}',
      'bowser-preserve:example.com/other': '{"f":{"draft":"private"}}',
      'website-preference': 'keep',
      [scrollKey]: JSON.stringify({ y: 320, at: now })
    });
    const session = storage({ 'bowser-preserve:example.com/page': 'private' });
    const listeners = {};
    const win = {
      scrollY: 0, innerHeight: 100,
      addEventListener(name, fn) { listeners[name] = fn; },
      scrollTo(x, y) { this.scrollY = y; }
    };
    const doc = {
      readyState: 'complete',
      scrollingElement: { scrollHeight: 1000 },
      querySelectorAll() { throw new Error('must not inspect form fields'); },
      addEventListener() { throw new Error('must not listen to input fields'); }
    };
    const context = {
      window: win, document: doc, location: { host: 'example.com', pathname: '/page' },
      localStorage: local, sessionStorage: session,
      setTimeout() {},
      setInterval() { throw new Error('must not poll form values'); }
    };
    vm.runInNewContext(process.argv[1], context);
    assert.equal(win.scrollY, 320);
    assert.equal(session.length, 0);
    assert.equal(local.getItem('website-preference'), 'keep');
    assert.ok(![...local.values.keys()].some(key => key.startsWith('bowser-preserve:')));
    win.scrollY = 0;
    listeners.scroll();
    const saved = JSON.parse(local.getItem(scrollKey));
    assert.deepEqual(Object.keys(saved).sort(), ['at', 'y']);
    assert.equal(saved.y, 0);
    assert.equal(typeof saved.at, 'number');
    assert.ok(!('input' in listeners) && !('keyup' in listeners));
    console.log('scroll-only preservation passed');
    """

    {output, status} = System.cmd("node", ["-e", harness, UserContent.preservation_script()], stderr_to_stdout: true)
    assert status == 0, output
  end

end
