defmodule Khymeia.Runtime.OSProcessTest do
  use ExUnit.Case, async: true

  alias Khymeia.Runtime.OSProcess

  test "decodes wrapper stream tags and sanitizes text" do
    assert {:stdout, "hello"} = OSProcess.decode("o hello")
    assert {:stderr, "oops"} = OSProcess.decode("e oops")
    assert {:stdout, ""} = OSProcess.decode("o")
    assert {:stdout, "red"} = OSProcess.decode("o \e[31mred\e[0m")
    assert {:stdout, "bad �"} = OSProcess.decode("o bad " <> <<0xFF>>)
  end

  test "reassembles lines delivered in chunks" do
    assert {:partial, buffer} = OSProcess.collect({:noeol, "o abc"}, [])
    assert {:partial, buffer} = OSProcess.collect({:noeol, "def"}, buffer)
    assert {:line, :stdout, "abcdefghi", []} = OSProcess.collect({:eol, "ghi"}, buffer)
  end

  test "runs a real process with argv (no shell interpretation) and reports exit status" do
    launch = %{executable: "/bin/echo", args: ["$HOME; echo pwned"]}
    {:ok, port} = OSProcess.open(launch, System.tmp_dir!())

    assert_receive {^port, {:data, {:eol, "o $HOME; echo pwned"}}}, 2_000
    assert_receive {^port, {:exit_status, 0}}, 2_000
  end

  test "daemon secrets are not passed to harnesses" do
    System.put_env("SECRET_KEY_BASE", "super-secret")
    on_exit(fn -> System.delete_env("SECRET_KEY_BASE") end)

    {:ok, port} = OSProcess.open(%{executable: "/usr/bin/env", args: []}, System.tmp_dir!())
    output = collect_output(port, [])

    refute output =~ "super-secret"
    assert output =~ "PATH="
  end

  defp collect_output(port, acc) do
    receive do
      {^port, {:data, {_, line}}} -> collect_output(port, [line | acc])
      {^port, {:exit_status, _}} -> acc |> Enum.reverse() |> Enum.join("\n")
    after
      2_000 -> flunk("no exit status")
    end
  end
end
