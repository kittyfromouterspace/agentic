%Doctor.Config{
  min_overall_spec_coverage: 0,
  struct_type_spec_required: false,
  ignore_modules: [
    AgentEx.AgentProtocol,
    AgentEx.AgentProtocol.CLI,
    AgentEx.ModelRouter.Free.Route,
    AgentEx.Protocol.Error.NotFound,
    AgentEx.Protocol.Error.Unavailable,
    AgentEx.Protocol.Error.SessionError,
    AgentEx.Storage.Context,
    AgentEx.Subagent.Coordinator,
    AgentEx.Tools,
    AgentEx.Tools.Gateway,
    AgentEx.Tools.Memory,
    AgentEx.Tools.Skill
  ]
}
