import std;

import config, target;

int main(string[] args)
{
	auto dashes = args.countUntil("--");
	if (dashes < 3 || dashes + 1 >= args.length)
	{
		writeln("Usage: ", args[0], " [projects folder] [dmd-old] [options...] -- [dmd-new] [options...]");
		return 1;
	}

	dubPath = environment.get("DUB_PATH", dubPath);

	string projectsDir = args[1];
	auto dmdOld = args[2];
	auto dmdOldArgs = args[3 .. dashes];
	auto dmdNew = args[dashes + 1];
	auto dmdNewArgs = args[dashes + 2 .. $];

	if (!exists(projectsDir))
	{
		writeln("Specified projects folder doesn't exist");
		return 1;
	}

	foreach (project; dirEntries(projectsDir, SpanMode.shallow).parallel)
	{
		if (project.isDir)
		{
			doProject(project, dmdOld, dmdOldArgs, dmdNew, dmdNewArgs);
		}
	}

	return 0;
}

enum Build
{
	buildOnly = 0,
	test = 1 << 0, // run unittests
	run = 1 << 1, // run program
}

void doProject(string cwd, string dmdOld, string[] dmdOldArgs, string dmdNew, string[] dmdNewArgs)
{
	compare(Build.test | Build.run, cwd, dmdOld, dmdOldArgs, dmdNew, dmdNewArgs);
}

void compare(Build buildTypes, string cwd, string dmdOld, string[] dmdOldArgs, string dmdNew, string[] dmdNewArgs)
{
	foreach (target; cwd.determineTargets)
		compare(buildTypes, target, dmdOld, dmdOldArgs, dmdNew, dmdNewArgs);
}

void compare(Build buildTypes, CompileTarget target, string dmdOld, string[] dmdOldArgs, string dmdNew, string[] dmdNewArgs)
{
	BitFlags!Build buildTypeFlags = buildTypes;

	if (target.match!(v => v.isBuildable))
		writeln("BUILD ", target);
	else
		writeln("SKIP ", target);

	if (buildTypeFlags.test && target.match!(v => v.isTestable))
		writeln("TEST ", target);

	if (buildTypeFlags.run && target.match!(v => v.isRunnable))
		writeln("RUN ", target);

	foreach (submodule; iterateSubmodules(target))
		compare(Build.test, submodule, dmdOld, dmdOldArgs, dmdNew, dmdNewArgs);

	foreach (example; findExamples(target))
		compare(Build.run, example, dmdOld, dmdOldArgs, dmdNew, dmdNewArgs);
}
