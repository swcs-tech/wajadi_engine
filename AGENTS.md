# Elixir Rules

## Naming Conventions
- snake_case for functions, variables, atoms, module attributes
- PascalCase for module names (e.g., MyApp.UserAccount)
- snake_case for file names matching module (e.g., user_account.ex)
- Predicate functions end with ? (e.g., valid?/1, empty?/1)
- Bang functions end with ! for raising versions (e.g., get!/1)
- Use `do_` for recursive workers or internal implementations that naturally correspond to a public function. Otherwise use a descriptive private function name.

## Typespecs and Docs
- Add `@spec` to stable public APIs, callbacks, and functions whose contracts are not obvious.
- Use domain-specific custom types where they improve API communication and Dialyzer analysis.
- Document non-obvious public types with `@typedoc`.
- Treat Elixir compiler type warnings separately from typespec and Dialyzer results; do not use broad `dynamic()` annotations merely to suppress useful diagnostics.
- Prefer to use `@moduledoc """..."""` even though it's just a brief description.
- Use `@moduledoc false` for modules that are intentionally internal or implementation details.
- Avoid leaving modules without any `@moduledoc` at all

## Data Access, Data Structure & Design Architecture
- Pattern Match First, Access Second only for data that is dynamic or optional.
- Respect Context Boundaries
- Avoid Circular Dependencies between contexts.
- Prefer MapSet when membership checks are repeated, uniqueness is part of the domain model, or set operations are required. For a small list or a single lookup, Enum.member?/2 is often simpler and may be cheaper overall.
- Use maps or structs for domain data and repeated key-based access. Use keyword lists primarily for function options and DSL-style configuration.

## Pattern Matching
- Prefer pattern matching in function heads over conditionals
- Prefix intentionally unused named variables with `_`, such as `_context`.
- Use `_` when the value must be ignored completely and should not be referenced later.
- Destructure function arguments when it possible and makes required data and invariants clearer.
- Avoid matching fields that the function does not use, especially at public or cross-context boundaries.

## Guards
- State accepted input conditions positively rather than describing every rejected case.
- A failed guard causes Elixir to try the next matching clause; if no clause matches, the call raises `FunctionClauseError`.
- State what you expect, not what you don't.
- Keep guards simple, readable, and limited to guard-safe expressions.

## Pipe Operator
- Use pipelines when they express a clear sequence of transformations on one conceptual value. Do not introduce a pipeline solely because there are two calls.
- First argument should be the data being transformed
- Prefer assigning the pipeline result before branching when it improves readability. Piping into case is acceptable for a short terminal branch.
- Keep pipes readable (one transformation per line)
- Use then/2 sparingly when transformation before matching is genuinely cleaner

## Expose higher-order function composition
- Write functions that operate on single items, then compose with `Enum.map/2`, `Stream`, `Task.async_stream/3`, etc.

## Eliminate single-call-site functions
- If a private function is only called once and isn't complex, consider inlining or using anonymous functions. Allow it if the goal is readability or breaking down functions that are too long (“Cyclomatic Complexity”).

## Error Handling
- Use `with` for short happy-path chains when each step returns compatible success and error shapes.
- Use `case` when failures require operation-specific handling or when the branch that failed must be identified.
- Keep `else` clauses small and generic. Avoid flattening unrelated failure shapes from multiple `with` clauses into one complex `else`.
- Prefer normalizing errors at appropriate layer boundaries instead of tagging every expression merely to identify which step failed.

## Avoid Step-Tagging in `with`
- Avoid tagging every with expression solely to distinguish errors in a large else. Prefer normalized domain errors, dedicated orchestration functions, or case when failures need operation-specific handling.

## Preserve Error Contracts in Pipelines
- Do not hide or collapse meaningful error contracts merely to preserve a pipeline. 
- Error transformation is acceptable when it adds domain context or converts explicitly between architectural layer boundaries.

## Tagged Errors and Exceptions
- Return tagged errors when the caller is expected to make a meaningful decision. Raise for programmer errors, invariant violations, or failures that cannot be represented meaningfully at that API boundary.

## Bang Functions and Failure Semantics
- Provide or use bang variants when failure represents a programmer error, violated invariant, invalid trusted configuration, or an unrecoverable condition at that API boundary.
- Prefer non-bang variants for external services, user input, expected absence, transient infrastructure failures, and any failure the caller may translate, retry, log, or present.
- Do not assume downstream or external services always return valid data merely because they are expected to do so.
- Let supervised processes crash only when restart is an intentional and safe recovery strategy.
- Use unified domain error types when callers need consistent handling across multiple integrations or subsystems.

## Ecto Queries, Schema & Changesets
- Use changesets for validation and transformation of data entering persistence-oriented Ecto workflows.
- Treat external input as untrusted and use `cast/4` when it enters an Ecto persistence workflow.
- Use `change/2` or direct constructors for trusted internal data when casting is unnecessary.
- Use plain functions or dedicated validators for domain validation that is unrelated to persistence.
- Use validate_* functions from Ecto.Changeset.
- Use changeset validations for early, user-facing feedback.
- Enforce persistence-critical invariants with database constraints such as `NOT NULL`, foreign keys, unique constraints, check constraints, and exclusion constraints where appropriate.
- Use changeset constraint functions to translate known database violations into structured changeset errors.
- Use separate `create_changeset/2` and `update_changeset/2` changesets when permitted fields, defaults, required fields, or invariants differ.
- Reuse a shared private changeset when the rules are genuinely identical.
- Use either keyword or expression syntax consistently according to readability.
- Use `dynamic/2`, named bindings, subqueries, or helper query functions for conditional and composable queries.
- Select only the fields required by read-heavy or high-volume queries.
- Optimize query shape, projection, preload strategy, and query count together; selecting fewer columns does not compensate for N+1 queries or excessive round trips.
- Prefer explicit maps or tuples for projections; avoid returning partially populated schemas unless their semantics are well understood.
- In prefix-based multi-tenancy, ensure the tenant prefix is applied consistently to every relevant read and write.
- Centralize tenant-context resolution and make propagation explicit across Tasks, background jobs, and asynchronous boundaries.
- Never derive the tenant solely from untrusted request parameters without authorization against the authenticated principal.
- Prefer UTC-aware `DateTime` values for persisted instants and events that represent a point in time.
- Use `NaiveDateTime` only when timezone or offset is intentionally undefined, such as a local recurring wall-clock value.

## Database
- Avoid issuing one `Repo.insert` or `Repo.update` per item for large homogeneous collections.
- Prefer set-based or bulk operations when per-record changesets, callbacks, and individual results are not required.
- Individual operations are acceptable for small collections or heterogeneous workflows when transaction semantics and measured throughput are acceptable.
- Be aware that `insert_all` bypasses changesets, changeset validations, and transformations implemented in application code before `Repo.insert`.
- It does not automatically generate ordinary schema fields such as `inserted_at` and `updated_at`; provide required values explicitly.
- Database defaults and adapter behavior still apply according to the target database and query.
- Explicitly provide any required timestamps or generated values.
- Use placeholders when they reduce repeated encoded values and are supported by the adapter.They are an optimization tool, not a requirement for every bulk insert.
- Derive chunk sizes from adapter parameter limits, row width, payload size, transaction duration, and measured throughput.
- Use `Ecto.Multi` to compose multiple named Repo operations that must succeed or fail as one transaction, especially when later operations depend on earlier results.
- Do not use `Ecto.Multi` merely as a bulk-performance mechanism. A Multi containing many individual inserts or updates still performs those operations individually.
- For large homogeneous collections, prefer `insert_all`, `update_all`, database-native upserts, staging tables, or other set-based operations when their reduced validation and callback semantics are acceptable.
- `Ecto.Multi.insert_all` may be used when a bulk operation must be composed atomically with other named transactional operations.
- Keep database transactions as short as possible and practical.
- Do not perform external network calls, filesystem operations, sleeps, uncontrolled computation, or unrelated long-running work while holding a database transaction.
- Keep only the database work required to preserve the transaction's invariant inside the transaction boundary.
- Add indexes based on measured query patterns, selectivity, cardinality, join paths, ordering requirements, and query plans. Foreign keys usually need indexes on the referencing side, but verify database-specific behavior.
- Validate important indexes with `EXPLAIN (ANALYZE, BUFFERS)` against representative data.
- Prevent race conditions with database constraints, atomic conditional updates, appropriate isolation levels, optimistic locking, advisory locks, or row locks according to the invariant.
- Use `Ecto.Multi` to compose the required operations transactionally, do not treat it as a concurrency-control mechanism by itself.

## Logging
- Use `Logger` for application diagnostics and operational events.
- Do not leave accidental `IO.inspect/2`, `dbg/2`, or ad hoc stdout debugging in production request paths or long-running services.
- `IO` output remains appropriate for intentional CLI and Mix task output.
- Use appropriate logging levels and emit structured metadata from a controlled allowlist.
- Treat schema redaction and formatter filtering as defense-in-depth.
- Use an allowlist for Logger metadata and never attach raw credentials, authorization headers, complete request bodies, or unrestricted external payloads.

## Debugging
- Use `dbg/2` to inspect pipeline values without restructuring code, debugging calls should not be left in the high-volume production path.

## GenServer & Processes
- Use GenServer for stateful processes (caches, rate limiters)
- Do NOT create one GenServer per persistent domain record merely to model object identity or replace ordinary modules and database access.
- Use GenServer when an entity genuinely requires serialized mutable runtime state, process lifecycle, timers, message handling, resource ownership, or concurrency coordination.
- Define explicitly whether the database, process state, event log, or external system is the authoritative source of truth.
- Handle every expected `handle_info/2` message explicitly. 
- Add a catch-all only when the process intentionally tolerates unknown messages.
- Record a bounded event name and message category rather than logging the complete arbitrary payload.
- Consider crashing instead when an unknown message indicates a violated protocol or corrupted lifecycle assumption.
- Prefer direct PID/reference passing when practical. 
- Use Registry-backed `:via` tuples when processes require stable, dynamically derived local names.

## HTTP Client
- Default to `Req` for HTTP requests. Do not introduce HTTPoison, Tesla, or other HTTP clients without a concrete interoperability, ecosystem, or migration justification.
- Define an explicit total latency budget for each integration, including receive timeout, connection timeout, pool checkout timeout, retry count, and backoff where applicable.
- Bound dependency latency to prevent cascading failures, while setting timeouts from measured service latency and the caller's total deadline rather than choosing arbitrarily small values.
- Configure transport-specific connection options through the selected Req adapter.
- Retry only transient, idempotent operations or operations protected by idempotency mechanisms.

## Process Communication
- Use `call` when acknowledgement, synchronous ordering, or a response is required. It may slow producers, but it is not a substitute for bounded admission control or demand-driven backpressure.
- Use `cast` only for intentionally asynchronous, best-effort commands whose overload and failure semantics are explicitly designed.
- Use `Task.async/await` for short-lived tasks whose lifecycle belongs to the caller.
- Always await, yield, or explicitly shut down tasks created with `Task.async`; do not start linked async tasks and ignore their results.
- Handle `{:exit, reason}` and timeout outcomes explicitly when consuming async streams.
- Use `Task.Supervisor` for dynamically supervised tasks or when link/failure semantics must be controlled independently.

## Resource Efficiency
- Prefer iodata/iolists when assembling output for APIs that accept iodata, especially repeated or large output construction.
- Prefer ordinary string interpolation or concatenation when it is clearer and the data is small; do not introduce iolists without a compatible consumer.
- Use `Enum` for eager transformations when results must be materialized.
- Use `Stream` when lazy production, early termination, composable enumeration, or avoidance of intermediate collections provides a measurable benefit.
- A Stream over an already materialized large list does not reduce the memory retained by the source list.
- Keep Stream transformations free of hidden side effects when possible.
- Remember that a Stream performs no work until it is enumerated, and may be enumerated zero, one, or multiple times depending on how it is consumed.
- Use `Application.compile_env` only when configuration genuinely affects compilation. Prefer runtime configuration for deploy-specific values and secrets. Resolve frequently used runtime config once during initialization rather than repeatedly in hot paths.
- In binary parsers, match fixed-size headers and validated length fields before variable-size payloads.
- Bound payload sizes before allocating, copying, or recursively parsing externally controlled binaries.
- If a long-lived process (such as a GenServer) stores a small sub-binary taken from a very large original binary (e.g., 100MB), consider `:binary.copy/1` to detach the retained slice and allow the original binary to be garbage-collected.
- Apply this only when the retained slice is small relative to the original binary, the process is long-lived, and measurement shows meaningful binary retention.

## Concurrency
- Set `max_concurrency` deliberately. For CPU-bound work, start near the available scheduler count. For I/O-bound work, derive it from downstream capacity, connection-pool size, rate limits, memory, and latency budgets.
- Use `Repo.stream` within a transaction when large result sets should be consumed incrementally instead of fully materialized, rather than loading all results into memory with `Repo.all`.
- Avoid accumulating streamed rows downstream, and keep the transaction and checked-out connection lifetime bounded.
- Distinguish between I/O-bound and CPU-bound workloads before selecting concurrency, timeout, and scheduling strategies.
- Consume every result produced by `Task.async_stream` and handle successful and exited task outcomes according to the operation's contract.
- Set `:timeout` and `:on_timeout` deliberately; do not assume a timeout is always returned as an ordinary stream element.
- Use `ordered: false` only when consumers do not depend on input order. This can reduce buffering and head-of-line blocking, but changes result ordering semantics.
- Design bounded admission and overload behavior. Use demand-driven systems such as `Broadway` or `GenStage` for suitable pipelines, but also enforce limits at ingress, queues, pools, rate limiters, and external brokers.
- Set timeouts deliberately from the caller's deadline, measured operation latency, failure semantics, and downstream capacity.
- Do not change a timeout merely because the framework default appears too short or too long.
- Ensure nested calls consume a bounded portion of the total request or job latency budget.
- Default to `:one_for_one`. Use `:rest_for_one` or `:one_for_all` only when restart coupling is an explicit invariant and startup order accurately models dependency.
- Avoid calling `Application.get_env/3` repeatedly in hot paths.
- Resolve runtime configuration during application or process initialization, then store it in process state or pass it explicitly.
- Use module attributes only for genuine compile-time constants.

## Security
- Never call `String.to_atom/1` on untrusted or externally controlled input (atom table exhaustion), because atoms are not garbage-collected during the VM's lifetime.
- Do not use Erlang external term format as a public serialization format for untrusted input.
- If compatibility requires decoding external terms, use `binary_to_term(binary, [:safe])` together with strict byte-size limits and resource controls.
- The `[:safe]` option restricts the creation of unsafe terms, but it does not prevent memory or CPU exhaustion and does not make arbitrary decoded data safe for application use.
- Prefer a bounded interoperable format such as JSON for untrusted external interfaces when its data model is sufficient.
- Compare secrets or authentication values using constant-time comparison after validating their expected representation and length.
- For variable-length source secrets, prefer comparing fixed-length cryptographic digests where the protocol permits it.
- Use hex or Base64 only when a canonical textual representation is required; `Plug.Crypto.secure_compare/2` accepts binaries directly.

## Observability & Telemetry
- Do not rely on logs for performance monitoring.
- Use a JSON formatter or logging backend when the deployment's log pipeline requires JSON.
- Use `:telemetry.span/3` for meaningful domain or integration boundaries.
- Prefer existing Ecto, Phoenix, Req, Broadway, and Oban telemetry events before wrapping low-level operations with duplicate custom spans.
- Use stable telemetry event names such as `[:my_app, :context, :operation]`.
- Put measurements such as `:duration`, `:queue_time`, and `:count` in the measurement map, not in the event name.
- Let `:telemetry.span/3` emit its standard `:start` event followed by either a `:stop` or `:exception` event, including the standard duration measurement on the terminal event.
- Add domain-specific measurements only when they have stable units, bounded cardinality, and clear aggregation semantics.
- Extract and validate supported distributed-tracing context at ingress.
- Propagate trace and span context through background jobs (Oban) and downstream requests using the tracing library's standard propagation format.
- Do not trust arbitrary user-provided trace identifiers as unrestricted log metadata.

## Anti-Patterns to Avoid
- Deeply nested or repetitive branching that obscures the decision model. Prefer function clauses, `with`, helper functions, or explicit state transitions when they improve clarity.
- Consider `comprehensions`, `flat_map`, or `reduce` when mapping and filtering large collections or when a single-pass formulation remains clear. 
- Do not sacrifice clarity to eliminate a small second traversal.
- Move non-interactive, retryable, or eventually consistent external work out of the request path into a supervised background job or durable queue, such as Oban when it fits the application's persistence and delivery model.
- Keep synchronous calls only when the response semantically depends on them, with strict latency budgets, timeouts, retry limits, and overload protection.
- rescue for control flow (use tagged tuples)
- throw/catch except for non-local returns in rare cases
- Introducing multiple HTTP client stacks without a concrete architectural or interoperability justification.
- Creating thin collection wrappers that merely mirror `Enum`, `Stream`, or `Task` without adding domain semantics, invariants, instrumentation, or reusable configuration.
- Tagging every `with` expression solely to route many unrelated failure shapes through one large `else` block.
- Catching broad exceptions merely to continue execution or hide invariant failures.
- Rescue only at boundaries that can add context, translate protocols, perform required cleanup, or apply an intentional recovery policy.
- Silently discarding errors, task exits, unexpected messages, failed job outcomes, or partial bulk-operation results.
- Handle, propagate, record, or deliberately classify every failure according to the boundary's contract.

# Tools

Note: Always use these tools to create migration file:
- `mix ecto.gen.migration <migration_name>` (empty file)
- `mix phx.gen.schema SchemaName table_name column1:type column2:type` (w/o namespace)

Note: Always use these tools to check the final results:
- `mix.precommit`
- `mix credo --all`

Note: Don't use these tools:
- `mix ecto.reset`

# References

## Amarula
https://amarula.hexdocs.pm/api-reference.html
https://amarula.hexdocs.pm/infrastructure.html
https://amarula.hexdocs.pm/custodian_benchmarks.html
https://amarula.hexdocs.pm/lid_pn.html
https://amarula.hexdocs.pm/going_prod.html
https://amarula.hexdocs.pm/parity.html
https://amarula.hexdocs.pm/pitfalls.html