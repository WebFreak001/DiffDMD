import std;

import core.atomic;

import mkalias, builder, config, target;

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

	auto dmdOldWrapper = makeAlias(dmdOld, dmdOldArgs);
	auto dmdNewWrapper = makeAlias(dmdNew, dmdNewArgs);

	writeln("old dmd --version: ", dmdOldWrapper);
	spawnProcess([dmdOldWrapper, "--version"]).wait;
	writeln("new dmd --version: ", dmdNewWrapper);
	spawnProcess([dmdNewWrapper, "--version"]).wait;

	if (!exists(projectsDir))
	{
		writeln("Specified projects folder doesn't exist");
		return 1;
	}

	auto allPaths = dirEntries(projectsDir, SpanMode.shallow).filter!(p => p.isDir).array;
	auto startTime = MonoTimeImpl!(ClockType.coarse).currTime;
	const total = allPaths.length;
	shared int counter;

	foreach (project; allPaths.parallel)
	{
		doProject(project, dmdOldWrapper, dmdNewWrapper);
		auto i = counter.atomicOp!"+="(1);
		if (true)
		{
			auto curTime = MonoTimeImpl!(ClockType.coarse).currTime;
			auto elapsed = (curTime - startTime).total!"msecs";
			auto progress = i / cast(double)total;
			auto remainingSecs = cast(int)((1 - progress) * elapsed / 1000);
			writeln("\x1b[1mDONE ", i, " / ", total, " - ETA: ", remainingSecs, "s\x1b[m");
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

void doProject(string cwd, string dmdOld, string dmdNew)
{
	compare(Build.buildOnly, cwd, dmdOld, dmdNew);
	// compare(Build.test | Build.run, cwd, dmdOld, dmdNew);
}

void compare(Build buildTypes, string cwd, string dmdOld, string dmdNew)
{
	foreach (target; cwd.determineTargets)
		compare(buildTypes, target, dmdOld, dmdNew);
}

void compare(Build buildTypes, CompileTarget target, string dmdOld, string dmdNew)
{
	BitFlags!Build buildTypeFlags = buildTypes;

	if (buildTypeFlags.run && target.match!(v => v.isRunnable))
	{
		// writeln("RUN ", target);
		target.runTarget(threadBuilderOld, dmdOld);
		target.runTarget(threadBuilderNew, dmdNew);
	}
	else if (target.match!(v => v.isBuildable))
	{
		// writeln("BUILD ", target);
		target.buildTarget(threadBuilderOld, dmdOld);
		target.buildTarget(threadBuilderNew, dmdNew);
	}
	else
		// writeln("SKIP ", target);

	if (buildTypeFlags.test && target.match!(v => v.isTestable))
	{
		// writeln("TEST ", target);
		target.testTarget(threadBuilderOld, dmdOld);
		target.testTarget(threadBuilderNew, dmdNew);
	}

	if (buildTypeFlags.test)
		foreach (submodule; iterateSubmodules(target))
			compare(Build.test, submodule, dmdOld, dmdNew);

	foreach (example; findExamples(target))
	{
		if (buildTypeFlags.run)
			compare(Build.run, example, dmdOld, dmdNew);
		else if (buildTypeFlags.test) // only build examples, don't assume they are valid testables
			compare(Build.buildOnly, example, dmdOld, dmdNew);
	}
}

NativeBuilder threadBuilderOld, threadBuilderNew;
shared int threadCounter = 0;
static this()
{
	int count = threadCounter.atomicOp!"+="(1);
	threadBuilderOld = makeThreadBuilder("old", count);
	threadBuilderNew = makeThreadBuilder("new", count);
}

private NativeBuilder makeThreadBuilder(string prefix, int id)
{
	auto output = new FileRecorder(File("out_" ~ prefix ~ "_" ~ id.to!string ~ ".log", "w"));
	return new NativeBuilder(output);
}
