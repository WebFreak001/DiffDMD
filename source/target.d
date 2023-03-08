module target;

import config;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.json;
import std.logger;
import std.path;
import std.process;
import std.string;
import std.sumtype;

enum InvokeType
{
	build,
	test,
	run
}

struct RecordOptions
{
	bool recordStdout = true;
	bool recordStderr = true;
	bool recordStatusCode = true;
	string[string] env = null;
}

interface Builder
{
	void start(InvokeType type, string id, const ref CompileTarget target);
	int record(string cwd, string program, string[] args, RecordOptions options = RecordOptions.init);
	void pushFile(string cwd, string file);
	void end();
}

struct DubCompileTarget
{
	enum TargetType
	{
		none,
		executable,
		library
	}

	string name;

	string directory;

	string targetCwd;

	string targetFile;
	string[] targetArgs;

	TargetType targetType;

	string targetPackage;
	string config;
	string[] extraDubArgs;

	JSONValue recipe;

	string toString() const @safe pure
		=> isBuildable
			? format!"[DUB] %s [%(%s %)] (%s) -> %s"(directory, dubArgs, targetType, targetFile)
			: format!"[DUB] %s [%(%s %)] (none)"(directory, dubArgs);

	bool isBuildable() const @safe pure
		=> targetType != TargetType.none && targetFile.length;

	bool isTestable() const @safe pure
		=> targetType != TargetType.none;

	bool isRunnable() const @safe pure
		=> targetType == TargetType.executable && targetFile.length;

	string[] dubArgs(string compiler = null) const @safe pure
	{
		string[] ret;
		if (targetPackage.length)
			ret ~= targetPackage;
		if (config.length)
			ret ~= text("--config=", config);
		ret ~= extraDubArgs;
		if (compiler.length)
			ret ~= text("--compiler=", compiler);
		return ret;
	}

	void build(Builder b, string compiler)
	{
		b.record(directory, dubPath, ["build", "--force"] ~ dubArgs(compiler));
		if (targetFile.length)
			b.pushFile(directory, targetFile);
	}

	void run(Builder b, string compiler)
	{
		auto args = ["run", "--force"] ~ dubArgs(compiler);
		if (targetArgs.length)
			args ~= ["--"] ~ targetArgs;
		b.record(directory, dubPath, args);
		if (targetFile.length)
			b.pushFile(directory, targetFile);
	}

	void test(Builder b, string compiler)
	{
		auto args = ["test", "--force"] ~ dubArgs(compiler);
		if (targetArgs.length)
			args ~= ["--"] ~ targetArgs;
		b.record(directory, dubPath, args);
		// TODO: determine unittest runner executable and record it
	}
}

struct RdmdCompileTarget
{
	string directory;

	string targetCwd;

	string targetFile;
	string[] targetArgs;

	string[] extraImports;

	bool isBuildable() const
		=> true;

	bool isTestable() const
		=> true;

	bool isRunnable() const
		=> true;

	void build(Builder b, string compiler)
	{
		assert(false);
	}

	void run(Builder b, string compiler)
	{
		assert(false);
	}

	void test(Builder b, string compiler)
	{
		assert(false);
	}
}

struct DmdICompileTarget
{
	string directory;

	string targetCwd;

	string targetFile;
	string[] targetArgs;

	string[] extraImports;

	bool isBuildable() const
		=> true;

	bool isTestable() const
		=> true;

	bool isRunnable() const
		=> true;

	void build(Builder b, string compiler)
	{
		assert(false);
	}

	void run(Builder b, string compiler)
	{
		assert(false);
	}

	void test(Builder b, string compiler)
	{
		assert(false);
	}
}

struct MesonCompileTarget
{
	string directory;

	string targetCwd;

	string targetFile;
	string[] targetArgs;

	bool isBuildable() const
		=> true;

	bool isTestable() const
		=> true;

	bool isRunnable() const
		=> true;

	void build(Builder b, string compiler)
	{
		assert(false);
	}

	void run(Builder b, string compiler)
	{
		assert(false);
	}

	void test(Builder b, string compiler)
	{
		assert(false);
	}
}

alias CompileTarget = SumType!(DubCompileTarget, RdmdCompileTarget, DmdICompileTarget, MesonCompileTarget);

void buildTarget(CompileTarget target, Builder b, string compiler)
{
	target.match!(
		(DubCompileTarget dub) {
			b.start(InvokeType.build, "dub/" ~ dub.name, target);
			scope (exit)
				b.end();
			dub.build(b, compiler);
		},
		_ => assert(false, "unimplemented")
	);
}

void runTarget(CompileTarget target, Builder b, string compiler)
{
	target.match!(
		(DubCompileTarget dub) {
			b.start(InvokeType.run, "dub/" ~ dub.name, target);
			scope (exit)
				b.end();
			dub.run(b, compiler);
		},
		_ => assert(false, "unimplemented")
	);
}

void testTarget(CompileTarget target, Builder b, string compiler)
{
	target.match!(
		(DubCompileTarget dub) {
			b.start(InvokeType.test, "dub/" ~ dub.name, target);
			scope (exit)
				b.end();
			dub.test(b, compiler);
		},
		_ => assert(false, "unimplemented")
	);
}

auto iterateTarget(string method)(return CompileTarget target)
{
	static struct S
	{
		CompileTarget target;

		int opApply(scope int delegate(CompileTarget) dg)
		{
			return mixin(method ~ "(target, dg)");
		}
	}

	return S(target);
}

int findSubmodules(CompileTarget target, scope int delegate(CompileTarget) dg)
{
	return target.match!(
		(DubCompileTarget base) {
			auto cwd = base.directory;
			if (auto subpkgs = "subPackages" in base.recipe)
			{
				foreach (subpkg; subpkgs.array)
				{
					DubCompileTarget[] subTargets;
					if (subpkg.type == JSONType.string)
						subTargets = parseDubTargets(buildPath(cwd, subpkg.str));
					else if (subpkg.type == JSONType.object)
						subTargets = parseDubJSONNothrow(cwd, subpkg, base, ":" ~ subpkg["name"].str);
					else
						assert(false, "Invalid subpackage: " ~ subpkg.toString);

					foreach (ref subTarget; subTargets)
						if (auto result = dg(CompileTarget(subTarget)))
							return result;
				}
			}
			return 0;
		},
		_ => 0
	);
}
alias iterateSubmodules = iterateTarget!"findSubmodules";

CompileTarget[] findExamples(CompileTarget target)
{
	return null;
}

bool isDubPackage(string cwd)
{
	return ["dub.json", "dub.sdl"].any!(p => cwd.chainPath(p).exists);
}

JSONValue readDubRecipeAsJson(string cwd)
{
	return execSimple([dubPath, "convert", "-s", "-f", "json"], cwd).parseJSON;
}

DubCompileTarget[] parseDubTargets(string cwd)
{
	try
	{
		return parseDubJSON(cwd, readDubRecipeAsJson(cwd));
	}
	catch (Exception e)
	{
		warning("Failed to parse DUB target in ", cwd);
		trace(e);
		return null;
	}
}

DubCompileTarget[] parseDubJSONNothrow(string cwd, JSONValue recipe, DubCompileTarget base = DubCompileTarget.init, string targetPackage = null)
{
	try
	{
		return parseDubJSON(cwd, recipe, base, targetPackage);
	}
	catch (Exception e)
	{
		warning("Failed to parse embedded DUB subpackage JSON in ", cwd);
		trace(e);
		return null;
	}
}

DubCompileTarget[] parseDubJSON(string cwd, JSONValue recipe, DubCompileTarget base = DubCompileTarget.init, string targetPackage = null)
{
	if (base.name.length)
		base.name ~= ":" ~ recipe["name"].str;
	else
		base.name = recipe["name"].str;
	base.targetCwd = base.directory = cwd;
	base.targetPackage = targetPackage;
	base.recipe = recipe;

	auto ret = appender!(DubCompileTarget[]);

	string[] describeArgs = ["--skip-registry=all"];

	if (targetPackage.length)
		describeArgs = targetPackage ~ describeArgs;

	string[] configs;
	if ("targetType" in recipe && recipe["targetType"].str == "none")
		{} // targetType is none, so no config listing as there cannot be any configs
	else
		configs = listDubConfigs(cwd, describeArgs);
	if (!configs.length)
	{
		base.targetType = DubCompileTarget.TargetType.none;
		return [base];
	}

	foreach (config; configs)
	{
		string[][] described;
		try
		{
			described = cwd.dubList(["target-type", "output-paths", "working-directory"], config, describeArgs);
		}
		catch (Exception)
		{
			// might be incompatible target-type
			described = cwd.dubList(["target-type", "output-paths"], config, describeArgs);
		}

		auto targetType = described[0].only;
		auto outputPaths = described[1];
		auto workingDirectory = described.length > 2 ? described[2].only : null;
		
		auto copy = base;
		copy.config = config;
		
		switch (targetType) with (DubCompileTarget.TargetType)
		{
		case "autodetect":
		case "library":
		case "none":
			if ("targetType" in recipe && recipe["targetType"].str == "sourceLibrary")
				goto case "sourceLibrary";

			assert(false, "dub describe must not return target-type '" ~ targetType ~ "'");
		case "staticLibrary":
		case "dynamicLibrary":
		case "sourceLibrary":
			copy.targetType = library;
			break;
		case "executable":
			copy.targetType = executable;
			break;
		default:
			assert(false, "Unimplemented target type: '" ~ targetType ~ "'");
		}

		if (outputPaths.length)
			copy.targetFile = outputPaths[0];

		copy.targetCwd = workingDirectory;

		ret ~= copy;
	}
	return ret.data;
}

CompileTarget[] determineTargets(string cwd)
{
	if (cwd.isDubPackage)
	{
		return parseDubTargets(cwd).map!CompileTarget.array;
	}
	else
	{
		assert(false, "not implemented target in " ~ cwd);
	}
}

/// Executes the given program in the given working directory and returns the
/// output as string. Uses execute internally. Throws an exception if the exit
/// status code is not 0.
string execSimple(string[] program, string cwd, size_t max = uint.max, bool withStderr = false)
{
	Config cfg;
	if (!withStderr)
		cfg = Config.stderrPassThrough;

	auto result = execute(program, null, cfg, max, cwd);
	enforce(result.status == 0, new RunException(result.status,
		format!"%(%s %) in %s failed with exit code %s:\n%s"
			(program, cwd, result.status, result.output)));
	return result.output;
}

class RunException : Exception
{
	int exitCode;

	this(int exitCode, string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
	{
		super(msg, file, line, nextInChain);
		this.exitCode = exitCode;
	}
}


string[][] dubList(string cwd, string[] lists, string config = null, string[] args = null)
{
	if (config.length)
		args ~= ("--config=" ~ config);

	return execSimple([
		dubPath,
			"describe"
			] ~ args ~ [
			"--data=" ~ lists.join(","),
			"--data-list",
			"--data-0",
	], cwd)
		.splitEmpty("\0\0")
		.map!(a => a.split("\0"))
		.array;
}

string[] listDubConfigs(string cwd, string[] args = null)
{
	return dubList(cwd, ["configs"], null, args ~ ["--skip-registry=all"])[0];

	// string[] configs;
	// foreach (line; execSimple([
	// 	dubPath,
	// 	"build",
	// 	"--print-configs",
	// 	"--annotate"
	// ], cwd).lineSplitter)
	// {
	// 	line = line.strip;
	// 	if (!configs.length && line.startsWith("Available configurations"))
	// 		continue;

	// 	auto end = line.countUntil(" [");
	// 	if (end == -1)
	// 		end = line.length;
	// 	configs ~= line[0 .. end];
	// }
	// return configs;
}

auto only(T)(scope inout(T)[] arr)
{
	assert(arr.length == 1, text(
			"Expected array to exactly contain 1 element, but got ", arr));
	return arr[0];
}

auto splitEmpty(T, Splitter)(T range, Splitter splitter)
{
	return range.length ? range.split(splitter) : [range];
}
