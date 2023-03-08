module builder;

import core.time;
import sha3d;
import std.array;
import std.base64;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.stdio;

import target;

alias ReceivedChunk = void delegate(scope ubyte[] chunk);
alias ReadCallback = void delegate(scope ReceivedChunk chunkCallback);

interface Recorder
{
	void start(InvokeType type, string id, const ref CompileTarget target);
	void recordLog(string stream, string line);
	void recordFile(string name, scope ReadCallback read);
	void end();

	final void recordFile(string name, string path)
	{
		if (!path.exists)
		{
			recordFile(name, (cb) {
				cb([]);
			});
			return;
		}

		recordFile(name, (cb) {
			ubyte[4096 * 4] buffer;
			foreach (chunk; File(path, "rb").byChunk(buffer[]))
				cb(chunk);
		});
	}
}

class NativeBuilder : Builder
{
	Recorder recorder;

	this(Recorder recorder)
	{
		this.recorder = recorder;
	}

	void start(InvokeType type, string id, const ref CompileTarget target)
	{
		recorder.start(type, id, target);
	}

	int record(string cwd, string program, string[] args,
			RecordOptions options = RecordOptions.init)
	{
		import core.sys.posix.poll;

		// auto stdin = File("/dev/null", "rb");
		// auto stdout = pipe();
		// auto stderr = pipe();
		// auto pid = spawnProcess(program ~ args, stdin, stdout.writeEnd, stderr.writeEnd, options.env, Config.none, cwd);

		// pollfd[2] pfds;
		// pfds[0].fd = stdout.readEnd.fileno;
		// pfds[0].events = POLLIN;
		// pfds[1].fd = stderr.readEnd.fileno;
		// pfds[1].events = POLLIN;
		// int numOpenFds = 2;

		// while (!pid.tryWait.terminated && numOpenFds > 2)
		// {
		// 	if (poll(pfds.ptr, pfds.length, -1) == -1)
		// 	{
		// 		.stderr.writeln("poll error");
		// 		break;
		// 	}

		// 	foreach (i, ref pfd; pfds)
		// 	{
		// 		if (pfd.revents != 0) {
		// 			if (pfd.revents & POLLIN) {
		// 				string channel = i == 0 ? "STDOUT" : "STDERR";
		// 				string line = i == 0 ? stdout.readEnd.readln : stderr.readEnd.readln;
		// 				recorder.recordLog(channel, line);
		// 			} else {
		// 				if (i == 0)
		// 					stdout.close();
		// 				else
		// 					stderr.close();
		// 				numOpenFds--;
		// 			}
		// 		}
		// 	}
		// }
		// stdout.close();
		// stderr.close();

		auto p = execute(program ~ args, options.env, Config.none, size_t.max, cwd);
		recorder.recordLog("ALL", p.output);
		recorder.recordLog("EXIT", "Exited with status code " ~ p.status.to!string);
		return p.status;
	}

	void pushFile(string cwd, string file)
	{
		recorder.recordFile(relativePath(file, cwd.absolutePath), buildPath(cwd, file));
	}

	void end()
	{
		recorder.end();
	}
}

class FileRecorder : Recorder
{
	File output;
	string id = null;
	MonoTime startTime;

	this(File output)
	{
		this.output = output;
	}

	void start(InvokeType type, string id, const ref CompileTarget target)
	{
		assert(this.id is null);
		output.writefln!"[START] %s %s %s"(type, id, target);
		this.id = id;
		startTime = MonoTime.currTime;
	}

	void end()
	{
		auto dur = MonoTime.currTime - startTime;
		output.writefln!"[END] %s in %s hnsecs"(id, dur.total!"hnsecs");
		output.flush();
		id = null;
		startTime = MonoTime.init;
	}

	void recordLog(string stream, string line)
	{
		output.writefln!"[OUT:%s] %s"(stream, line.replace("\n", text("\n[OUT:", stream, "]")));
	}

	void recordFile(string name, scope ReadCallback read)
	{
		KECCAK!(256, 6 * 8) sha;
		read((chunk) {
			sha.put(chunk);
		});
		output.writefln!"[FILE] [%s] %s"(Base64.encode(sha.finish()), name);
	}
}

// class PostgresRecorder : Recorder
// {
// }
