defmodule BowserBrain.EngineBuild do
  @moduledoc false
  # Bowser ships a thin arm64 Mach-O. Read only its bounded load-command area,
  # not the entire executable, on each check for replacement at the same path.
  def disk_id(path) when is_binary(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, 32) do
          <<0xFEEDFACF::little-32, _cpu::binary-size(12), count::little-32,
            size::little-32, _flags::binary-size(8)>> when size <= 1_048_576 ->
            case IO.binread(file, size) do
              data when is_binary(data) -> uuid(data, count)
              _ -> nil
            end
          _ -> nil
        end
      after
        File.close(file)
      end
    else
      _ -> nil
    end
  end
  def disk_id(_), do: nil

  defp uuid(<<0x1B::little-32, 24::little-32, id::binary-size(16), _::binary>>, n) when n > 0,
    do: Base.encode16(id, case: :lower)
  defp uuid(<<_kind::little-32, size::little-32, rest::binary>>, n) when n > 0 and size >= 8 do
    case rest do
      <<_::binary-size(size - 8), tail::binary>> -> uuid(tail, n - 1)
      _ -> nil
    end
  end
  defp uuid(_, _), do: nil

  def status(hello) do
    running = hello["engine_build_id"]
    disk = disk_id(hello["engine_binary"])
    %{running: running, disk: disk,
      stale: if(is_binary(running) and is_binary(disk), do: running != disk, else: nil)}
  end
end
