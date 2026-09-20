defmodule Alkim.Harness.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Alkim.Harness.{Discovery, Executable, Fake}

  defmodule Missing do
    @behaviour Alkim.Harness
    def id, do: :missing
    def name, do: "Missing harness"
    def detect, do: :not_found
    def capabilities, do: %Alkim.Harness.Capabilities{}
    def build_command(_turn), do: {:error, :not_installed}
    def parse_output(_stream, _line), do: []
  end

  test "reports installed, missing and planned harnesses" do
    planned = [%{id: :ghost, name: "Ghost CLI", executable: "alkim-definitely-not-installed"}]
    results = Discovery.scan([Fake, Missing], planned)

    assert [fake, missing, ghost] = results

    assert %{id: :fake, status: :available, adapter: Fake, version: "demo"} = fake
    assert fake.capabilities.streaming
    assert "hang" in Enum.map(fake.models, & &1.id)
    assert fake.executable =~ "alkim-fake-harness"

    assert %{id: :missing, status: :not_installed, executable: nil, models: []} = missing
    assert %{id: :ghost, status: :not_installed, adapter: nil} = ghost
  end

  defmodule Reporting do
    @behaviour Alkim.Harness
    def id, do: :reporting
    def name, do: "Reporting harness"
    def detect, do: {:ok, %{executable: "/bin/sh", version: nil}}
    def capabilities, do: %Alkim.Harness.Capabilities{model_selection: true}
    def list_models("/bin/sh"), do: {:ok, [%{id: "m1", name: "Model 1", description: nil}]}
    def build_command(_turn), do: {:error, :not_used}
    def parse_output(_stream, _line), do: []
  end

  defmodule Silent do
    @behaviour Alkim.Harness
    def id, do: :silent
    def name, do: "Silent harness"
    def detect, do: {:ok, %{executable: "/bin/sh", version: nil}}
    def capabilities, do: %Alkim.Harness.Capabilities{model_selection: true}
    def list_models(_), do: :error
    def build_command(_turn), do: {:error, :not_used}
    def parse_output(_stream, _line), do: []
  end

  test "models reported by the CLI are cached; failures fall back to none" do
    assert [reporting, silent] = Discovery.scan([Reporting, Silent], [])
    assert [%{id: "m1"}] = reporting.models
    assert silent.models == []
  end

  test "an installed planned harness is reported without an adapter" do
    planned = [%{id: :shell, name: "A shell", executable: "sh"}]
    assert [%{status: :no_adapter, executable: path}] = Discovery.scan([], planned)
    assert path =~ ~r{/sh$}
  end

  test "planned harnesses that have an adapter are not listed twice" do
    planned = [%{id: :fake, name: "Fake", executable: "fake"}]
    assert [%{id: :fake, status: :available}] = Discovery.scan([Fake], planned)
  end

  test "the running Discovery process caches results and can refresh" do
    cached = Discovery.list()
    assert Enum.any?(cached, &(&1.id == :fake and &1.status == :available))
    assert Discovery.refresh() == cached
    assert {:ok, %{id: :fake}} = Discovery.fetch_available(:fake)
    assert {:error, :unknown_harness} = Discovery.fetch_available(:nope)
  end

  describe "Executable" do
    test "a pinned binary overrides PATH lookup" do
      System.put_env("ALKIM_PINNED_BIN", "/bin/sh")
      on_exit(fn -> System.delete_env("ALKIM_PINNED_BIN") end)

      assert {:ok, "/bin/sh"} = Executable.find(:pinned, "whatever")
    end

    test "missing executables are not found" do
      assert :not_found = Executable.find(:nothing, "alkim-definitely-not-installed")
    end

    test "the search path includes conventional install locations" do
      assert Executable.search_path() =~ Path.expand("~/.local/bin")
      assert Executable.search_path() =~ "/opt/homebrew/bin"
    end
  end
end
