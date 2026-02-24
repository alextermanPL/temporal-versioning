# Temporal Dynamic Configuration

This directory contains dynamic configuration files for Temporal server.

## Files

- `development-sql.yaml` - Configuration optimized for local development with PostgreSQL

## What is Dynamic Config?

Dynamic config allows you to change Temporal's behavior without restarting the server.
Each key can have zero or more values, and each value can have zero or more constraints.

## Available Constraints

1. `namespace`: `string` - Apply to specific namespace
2. `taskQueueName`: `string` - Apply to specific task queue
3. `taskType`: `int` - Apply to specific task type (`1`: Workflow, `2`: Activity)

## Example Usage

```yaml
# Global setting
limit.maxIDLength:
  - value: 255
    constraints: {}

# Namespace-specific setting
frontend.namespaceRPS:
  - value: 1000
    constraints:
      namespace: "default"
  - value: 500
    constraints:
      namespace: "test"
```

## Common Configuration Options

- `limit.maxIDLength` - Maximum length for workflow/activity IDs
- `system.forceSearchAttributesCacheRefreshOnRead` - Force search attributes cache refresh
- `frontend.persistenceMaxQPS` - Max queries per second to persistence layer
- `history.persistenceMaxQPS` - Max QPS for history service
- `matching.persistenceMaxQPS` - Max QPS for matching service

## References

- [Temporal Dynamic Config Documentation](https://docs.temporal.io/references/dynamic-configuration)
- [Full list of configuration keys](https://github.com/temporalio/temporal/blob/master/common/dynamicconfig/constants.go)
