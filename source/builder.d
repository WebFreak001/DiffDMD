module builder;

import std.base64;
import std.file;
import std.path;
import std.process;
import std.stdio;
import sha3d;

import target;

enum InvokeType
{
	build,
	test,
	run
}

alias ReceivedChunk = void delegate(scope ubyte[] chunk);
alias ReadCallback = void delegate(scope ReceivedChunk chunkCallback);

interface Recorder
{
	void start(InvokeType type, string revision, CompileTarget target);
	void recordLog(string stream, string line);
	void recordFile(string name, scope ReadCallback read);
}

class NativeBuilder : Builder
{
	Recorder recorder;

	int record(string cwd, string program, string[] args,
			RecordOptions options = RecordOptions.init)
	{
		return spawnProcess(program ~ args, options.env, Config.none, cwd).wait;
	}

	void pushFile(string cwd, string file)
	{
		recorder.recordFile(relativePath(file, cwd), (cb) {
			ubyte[4096] buffer;
			foreach (chunk; File(buildPath(cwd, file), "rb").byChunk(buffer[]))
				cb(chunk);
		});
	}
}

class StdoutRecorder : Recorder
{
	void start(InvokeType type, string revision, CompileTarget target)
	{
		writefln!"Start %s %s %s"(type, revision, target);
	}

	void recordLog(string stream, string line)
	{
		writefln!"[%s] %s"(stream, line);
	}

	void recordFile(string name, scope ReadCallback read)
	{
		KECCAK!(256, 6 * 8) sha;
		read((chunk) {
			sha.put(chunk);
		});
		writefln!"[FILE] [%s] %s"(Base64.encode(sha.finish()), name);
	}
}

// class PostgresRecorder : Recorder
// {
// }
