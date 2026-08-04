defmodule WajadiEngine.WhatsApp.SessionCleanupSchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias WajadiEngine.WhatsApp.SessionCleanupScheduler

  test "does not start when disabled" do
    assert :ignore = SessionCleanupScheduler.start_link(enabled?: false)
  end

  test "runs cleanup on start and schedules the next run" do
    parent = self()

    cleanup_fun = fn opts ->
      send(parent, {:cleanup, opts})
      %{selected: 1, purged: 1, skipped: 0, failed: 0}
    end

    start_supervised!(
      {SessionCleanupScheduler,
       enabled?: true,
       interval_ms: 50,
       batch_size: 7,
       run_on_start?: true,
       cleanup_fun: cleanup_fun}
    )

    assert_receive {:cleanup, [batch_size: 7]}, 500
    assert_receive {:cleanup, [batch_size: 7]}, 500
  end

  test "continues scheduling after cleanup failure" do
    parent = self()
    counter = :counters.new(1, [])

    cleanup_fun = fn opts ->
      :counters.add(counter, 1, 1)
      count = :counters.get(counter, 1)
      send(parent, {:cleanup, opts, count})

      if count == 1 do
        raise "boom"
      else
        %{selected: 0, purged: 0, skipped: 0, failed: 0}
      end
    end

    capture_log(fn ->
      start_supervised!(
        {SessionCleanupScheduler,
         enabled?: true,
         interval_ms: 50,
         batch_size: 3,
         run_on_start?: true,
         cleanup_fun: cleanup_fun}
      )

      assert_receive {:cleanup, [batch_size: 3], 1}, 500
      assert_receive {:cleanup, [batch_size: 3], 2}, 500
    end)
  end
end
