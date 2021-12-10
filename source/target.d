module target;

import config;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.json;
import std.path;
import std.process;
import std.string;
import std.sumtype;

struct DubCompileTarget
{
	enum TargetType
	{
		none,
		executable,
		library
	}

	string directory;

	string targetCwd;

	string targetFile;
	string[] targetArgs;

	TargetType targetType;

	string targetPackage;
	string config;
	string[] dubArgs;

	JSONValue recipe;

	string toString() const @safe pure
		=> isBuildable
			? format!"[DUB] %s %s %s %s (%s) -> %s"(directory, targetPackage, dubArgs, config, targetType, targetFile)
			: format!"[DUB] %s %s (none)"(directory, targetPackage);

	bool isBuildable() const @safe pure
		=> targetType != TargetType.none && targetFile.length;

	bool isTestable() const @safe pure
		=> targetType != TargetType.none;

	bool isRunnable() const @safe pure
		=> targetType == TargetType.executable && targetFile.length;
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
}

alias CompileTarget = SumType!(DubCompileTarget, RdmdCompileTarget, DmdICompileTarget, MesonCompileTarget);

auto iterateSubmodules(return CompileTarget target)
{
	static struct S
	{
		CompileTarget target;

		int opApply(scope int delegate(CompileTarget) dg)
		{
			return findSubmodules(target, dg);
		}
	}

	return S(target);
}

int findSubmodules(CompileTarget target, scope int delegate(CompileTarget) dg)
{
	return target.match!(
		(DubCompileTarget base) {
			auto cwd = base.directory;
			auto subpkgs = "subPackages" in base.recipe;
			if (!subpkgs)
				return 0;
			int result;
			Outer: foreach (subpkg; subpkgs.array)
			{
				DubCompileTarget[] subTargets;
				string subName;

				if (subpkg.type == JSONType.string)
				{
					subTargets = parseDubTargets(buildPath(cwd, subpkg.str));
				}
				else if (subpkg.type == JSONType.object)
				{
					subTargets = parseDubJSON(cwd, subpkg, base, ":" ~ subpkg["name"].str);
				}
				else
					assert(false, "Invalid subpackage: " ~ subpkg.toString);

				foreach (ref subTarget; subTargets)
				{
					result = dg(CompileTarget(subTarget));
					if (result)
						break Outer;
				}
			}
			return result;
		},
		_ => 0
	);
}

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
	return parseDubJSON(cwd, readDubRecipeAsJson(cwd));
}

DubCompileTarget[] parseDubJSON(string cwd, JSONValue recipe, DubCompileTarget base = DubCompileTarget.init, string targetPackage = null)
{
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
	enforce(result.status == 0,
		format!"%(%s %) in %s failed with exit code %s:\n%s"
			(program, cwd, result.status, result.output));
	return result.output;
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
