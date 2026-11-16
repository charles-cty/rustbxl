// Runtime paths are tracked configuration inputs, never source substitutions.
config({
    resolvers: [{
        kind: "DScript",
        modules: [
            f`module.config.dsc`,
            Environment.getDirectoryValue("RUSTBXL_SDK").combine("Sdk.Transformers/package.config.dsc"),
            Environment.getDirectoryValue("RUSTBXL_SDK").combine("Sdk.Json/module.config.dsc"),
        ],
    }],
    mounts: [
        { name: a`Worktree`, path: Environment.getPathValue("RUSTBXL_SOURCE"), isReadable: true, isWritable: false, isSystem: true, trackSourceFileChanges: true },
        { name: a`Target`, path: Environment.getPathValue("RUSTBXL_TARGET"), isReadable: true, isWritable: true, isSystem: true, trackSourceFileChanges: true },
        { name: a`SidecarState`, path: Environment.getPathValue("RUSTBXL_STATE"), isReadable: true, isWritable: true, trackSourceFileChanges: true },
        { name: a`UserProfile`, path: Environment.getPathValue("USERPROFILE"), isReadable: true, isWritable: false, trackSourceFileChanges: true },
        { name: a`ProgramData`, path: Environment.getPathValue("ProgramData"), isReadable: true, isWritable: false, trackSourceFileChanges: true },
    ],
});
