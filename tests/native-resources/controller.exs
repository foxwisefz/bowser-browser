[root] = System.argv()
Code.require_file(Path.join(root, "beam/lib/bowser_brain/core_feature.ex"))
source = File.read!(Path.join(root, "beam/lib/bowser_brain/resource_controller.ex"))
Code.compile_string(source)
IO.puts(JSON.encode!(%{ready: true}))
for line <- IO.stream(:stdio, :line) do
  result = case JSON.decode!(line) do
    %{"reload" => true} ->
      Code.put_compiler_option(:ignore_module_conflict, true)
      Code.compile_string(String.replace(source, "after: intent[\"after\"]", "after: !intent[\"after\"]"))
      %{reloaded: true}
    event -> BowserBrain.ResourceController.decision(event)
  end
  IO.puts(JSON.encode!(result))
end
