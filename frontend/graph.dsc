import {Transformer, Cmd} from "Sdk.Transformers";
import * as Json from "Sdk.Json";

interface GraphInput {
    kind: string;
    path: string;
    producer?: string;
    directory?: string;
}

interface GraphEnvironment {
    name: string;
    value: string;
    paths?: string[];
}

interface GraphNode {
    id: string;
    kind: string;
    tool?: GraphInput;
    arguments: string[];
    workingDirectory?: string;
    tempDirectory?: string;
    environment: GraphEnvironment[];
    dependencies: GraphInput[];
    outputDirectories: string[];
    untrackedFiles: string[];
    consoleOutput?: string;
    traceFile?: string;
    disableCacheLookup: boolean;
    source?: GraphInput;
    destination?: string;
}

interface Graph {
    version: number;
    nodes: GraphNode[];
}

interface Scheduled {
    process?: Transformer.ExecuteResult;
    file?: File;
}

type Schedule = Map<string, Scheduled>;

function file(input: GraphInput, scheduled: Schedule): File {
    Contract.requires(input.kind === "file", "Expected a file reference");
    if (!input.producer) {
        return f`${input.path}`;
    }
    Contract.requires(scheduled.containsKey(input.producer), "Missing or unordered file producer");
    const owner = scheduled.get(input.producer);
    if (owner.file) {
        return owner.file;
    }
    return input.directory
        ? owner.process.getOutputDirectory(d`${input.directory}`).assertExistence(p`${input.path}`)
        : owner.process.getOutputFile(p`${input.path}`);
}

function dependency(input: GraphInput, scheduled: Schedule): Transformer.InputArtifact {
    Contract.requires(input.kind === "file" || input.kind === "directory", "Unknown input kind");
    Contract.requires(!input.producer || scheduled.containsKey(input.producer), "Missing or unordered dependency producer");
    return input.kind === "directory"
        ? scheduled.get(input.producer).process.getOutputDirectory(d`${input.path}`)
        : file(input, scheduled);
}

function schedule(scheduled: Schedule, node: GraphNode): Schedule {
    Contract.requires(!scheduled.containsKey(node.id), "Duplicate graph node");
    if (node.kind === "copy") {
        return scheduled.add(node.id, {
            file: Transformer.copyFile(file(node.source, scheduled), p`${node.destination}`),
        });
    }
    Contract.requires(node.kind === "process", "Unknown graph node kind");
    const result = Transformer.execute({
        tool: {
            exe: file(node.tool, scheduled),
            dependsOnWindowsDirectories: true,
            prepareTempDirectory: true,
            untrackedFiles: node.untrackedFiles.map(path => f`${path}`),
        },
        description: node.id,
        workingDirectory: d`${node.workingDirectory}`,
        tempDirectory: node.tempDirectory ? d`${node.tempDirectory}` : undefined,
        // Each complete argument is escaped once by BuildXL's command-line API.
        arguments: node.arguments.map(value => value.length === 0 ? Cmd.rawArgument("\"\"") : Cmd.argument(value)),
        environmentVariables: node.environment.map(entry => ({
            name: entry.name,
            value: entry.paths ? entry.paths.map(path => p`${path}`) : entry.value,
        })),
        dependencies: node.dependencies.map(input => dependency(input, scheduled)),
        outputs: node.outputDirectories.map(path => d`${path}`),
        consoleOutput: node.consoleOutput ? p`${node.consoleOutput}` : undefined,
        fileAccessTraceFile: node.traceFile ? p`${node.traceFile}` : undefined,
        allowUndeclaredSourceReads: true,
        disableCacheLookup: node.disableCacheLookup,
    });
    return scheduled.add(node.id, {process: result});
}

const graph = Json.read<Graph>(File.readAllText(f`${Environment.getPathValue("RUSTBXL_GRAPH")}`));
function buildGraph(): Schedule {
    Contract.requires(graph.version === 1, "Unsupported process graph version");
    return graph.nodes.reduce((scheduled, node) => schedule(scheduled, node), Map.empty<string, Scheduled>());
}

export const pips = buildGraph();
