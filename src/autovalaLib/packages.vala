/*
 Copyright 2013/2014 (C) Raster Software Vigo (Sergio Costas)

 This file is part of AutoVala

 AutoVala is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 3 of the License, or
 (at your option) any later version.

 AutoVala is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>. */

using GLib;
using Gee;
using Posix;

namespace AutoVala {

	private class packages : Object {

		// Contains the author of the package, as will be put in the metadata
		public string? author_package;
		// Contains the author's email, as will be put in the metadata
		public string? email_package;
		// Contains the description to add to the package.
		public string? description;
		// A list of the files needed for running the project, extracted automatically by autovala
		public Gee.List<string> dependencies;
		// A list of the files needed for building the project, extracted automatically by autovala
		public Gee.List<string> source_dependencies;
		// A list of the files needed for running the project, added manually in the .avprj file
		public Gee.List<string> extra_dependencies;
		// A list of the files needed for building the project, added manually in the .avprj file
		public Gee.List<string> extra_source_dependencies;

		// The system command to run before installing the package
		protected string[] pre_inst;
		// The system command to run after installing the package
		protected string[] post_inst;
		// The system command to run before removing the package
		protected string[] pre_rm;
		// The system command to run after removing the package
		protected string[] post_rm;


		protected Configuration config;
		private bool has_libraries;
		private bool has_icons;
		private bool has_schemes;

		private Gee.Map<string,string> libraries;

		public void show_errors() {
			this.config.showErrors();
		}

		public packages() {

			this.author_package = null;
			this.email_package = null;
			this.description = null;
			this.dependencies = new ArrayList<string>();
			this.source_dependencies = new ArrayList<string>();
			this.extra_dependencies = new ArrayList<string>();
			this.extra_source_dependencies = new ArrayList<string>();

			this.pre_inst = {};
			this.pre_rm = {};
			this.post_inst = {};
			this.post_rm = {};

			this.libraries = new Gee.HashMap<string,string>();
			this.has_libraries = false;
			this.has_icons = false;
			this.has_schemes = false;

		}

		/**
		 * Second part of the initialization process. Here the class reads the configuration file,
		 * fills the dependencies, and sets the compiler version.
		 * @param basePath The configuration file to use, or null to make the class find it
		 * @return false if everything went fine; true if there was an error
		 */
		public bool init_all(Configuration config) {

			this.config = config;

			// Try to read the description from the README or README.md file
			if (!this.read_description(Path.build_filename(this.config.globalData.projectFolder,"README"))) {
				if (!this.read_description(Path.build_filename(this.config.globalData.projectFolder,"README.md"))) {
					this.description = "Not available";
				}
			}
			this.description = this.cut_lines(this.description,70);
			this.read_defaults();
			this.fill_libraries("/lib");
			this.fill_libraries("/usr/lib");
			this.read_library_paths("/etc/ld.so.conf");

			// Fill the dependencies
			foreach (var element in config.globalData.globalElements) {
				if (element.eType == ConfigType.SOURCE_DEPENDENCY) {
					if (!this.extra_source_dependencies.contains(element.name)) {
						this.extra_source_dependencies.add(element.name);
					}
				}
				if (element.eType == ConfigType.BINARY_DEPENDENCY) {
					if (!this.extra_dependencies.contains(element.name)) {
						this.extra_dependencies.add(element.name);
					}
				}
				if (element.eType == ConfigType.VALA_LIBRARY) {
					this.has_libraries = true;
				}
				if (element.eType == ConfigType.ICON) {
					this.has_icons = true;
				}
				if (element.eType == ConfigType.SCHEME) {
					this.has_schemes = true;
				}
			}
			foreach (var element in config.globalData.globalElements) {
				if ((element.eType == ConfigType.VALA_LIBRARY) || (element.eType == ConfigType.VALA_BINARY)) {
					var binElement = element as ElementValaBinary;
					foreach (var p in binElement.packages) {
						if ((p.type != packageType.DO_CHECK) && (p.type != packageType.C_DO_CHECK)) {
							continue;
						}

						var module = p.elementName;
						var library = Globals.vapiList.get_pc_path(module);
						if (library == null) {
							continue;
						}
						if ((this.source_dependencies.contains(library)) || (this.extra_source_dependencies.contains(library))) {
							continue;
						}
						this.source_dependencies.add(library);
						var bindeps = this.read_dependencies(module);
						foreach (var fullname in bindeps) {
							if (this.libraries.has_key(fullname)) {
								var lpath = this.libraries.get(fullname);
								if ((this.dependencies.contains(lpath)) || (this.extra_dependencies.contains(lpath))) {
									continue;
								}
								this.dependencies.add(lpath);
							} else {
								ElementBase.globalData.addWarning(_("Failed to find dependencies for the module %s").printf(module));
							}
						}
					}
				}
			}

			if (this.has_libraries) {
				this.post_inst += "ldconfig";
				this.post_rm += "ldconfig";
			}

			if (this.has_schemes) {
				this.post_inst += "glib-compile-schemas /usr/share/glib-2.0/schemas";
				this.post_rm += "glib-compile-schemas /usr/share/glib-2.0/schemas";
			}

			var compilers = new FindVala();
			if (compilers == null) {
				ElementBase.globalData.addWarning(_("Failed to get installed vala compilers"));
			} else {
				// if the desired VALA version is installed in the system, go ahead with it
				if (false == this.set_vala_version(compilers,this.config.globalData.valaVersionMajor,this.config.globalData.valaVersionMinor)) {
					// if not, go ahead with the default version (it's supposed that the maintainer has checked the code against this version)
					this.set_vala_version(compilers,compilers.defaultVersion.major,compilers.defaultVersion.minor);
				}
			}
			return false;
		}

		private bool set_vala_version(FindVala compilers, int major, int minor) {

			foreach (var element in compilers.versions) {
				if ((element.major == major) && (element.minor == minor)) {
					if ((!this.source_dependencies.contains(element.path)) && (!this.extra_source_dependencies.contains(element.path))) {
						this.source_dependencies.add(element.path);
					}
					return true;
				}
			}
			return false;
		}

		/**
		 * Reads all the library dependencies from a module using pkg-config
		 * @param module The module that we want to get the compilation dependencies
		 * @return A list of libraries needed to compile it
		 */
		private string[] read_dependencies(string module) {

			string[] spawn_args = {"pkg-config", module, "--libs-only-l"};
			string ls_stdout;
			int ls_status;
			string[] list = {};

			try {
				if (!Process.spawn_sync (null,spawn_args,Environ.get(),SpawnFlags.SEARCH_PATH,null,out ls_stdout,null,out ls_status)) {
					ElementBase.globalData.addWarning(_("Failed to launch pkg-config for the module %s").printf(module));
					return {};
				}
				if (ls_status != 0) {
					ElementBase.globalData.addWarning(_("Error %d when launching pkg-config for the module %s").printf(ls_status,module));
					return {};
				}
			} catch (SpawnError e) {
				ElementBase.globalData.addWarning(_("Exception '%s' when launching pkg-config for the module %s").printf(e.message,module));
				return {};
			}
			var elements = ls_stdout.split(" ");
			foreach(var element in elements) {
				var l = element.strip();
				if (!l.has_prefix("-l")) {
					continue;
				}
				list += "lib"+l.substring(2)+".so";
			}
			return (list);
		}

		/**
		 * Reads all the paths where libraries are stored, starting with the ones at /etc/ld.so.conf
		 * @param path The path of the config file to parse and extract paths. It processes recursively INCLUDE paths
		 */
		private void read_library_paths(string path) {
			var file = File.new_for_path(path);
			if (!file.query_exists()) {
				return;
			}
			try {
				var dis = new DataInputStream(file.read());
				string line;
				while ((line = dis.read_line (null)) != null) {
					var line2 = line.strip();
					if ((line2 == "") || (line2[0]=='#')) {
						continue;
					}
					if (line2.has_prefix("include ")) {
						var incpath = line2.substring(8).strip();
						var paths = Posix.Glob();
						paths.glob(incpath,0);
						foreach (var newpath in paths.pathv) {
							this.read_library_paths(newpath);
						}
						continue;
					}
					this.fill_libraries(line2);
				}
			} catch (Error e) {
			}
		}

		/**
		 * Reads all the libraries in the specified path and stores them in this.libraries, to be able to get the dependencies for the project
		 * @param path The path into which search for libraries
		 */
		private void fill_libraries(string path) {

			if (path.has_prefix("/usr/local")) {
				return; // /usr/local is not stored in packages
			}

			try {
				var directory = File.new_for_path (path);

				var enumerator = directory.enumerate_children (FileAttribute.STANDARD_NAME+","+FileAttribute.STANDARD_IS_SYMLINK+","+FileAttribute.STANDARD_SYMLINK_TARGET, 0);

				FileInfo file_info;
				while ((file_info = enumerator.next_file ()) != null) {
				    var filename=file_info.get_name();
				    if ((filename.has_prefix("lib")) && (filename.has_suffix(".so"))) {
				    	if (file_info.get_is_symlink()) {
					    	this.libraries.set(filename,Path.build_filename(file_info.get_symlink_target()));
				    	} else {
				    		this.libraries.set(filename,Path.build_filename(path,filename));
				    	}
				    }
				}
			} catch (Error e) {
			}
		}

		public void read_defaults() {

			var file = File.new_for_path(Path.build_filename(GLib.Environment.get_home_dir(),".config","autovala","packages.cfg"));
			if (!file.query_exists()) {
				return;
			}
			try {
				var dis = new DataInputStream (file.read ());
				string line;
				this.author_package = null;
				this.email_package = null;
				while ((line = dis.read_line (null)) != null) {
					if (line.has_prefix("author_package: ")) {
						this.author_package = line.substring(16).strip();
						continue;
					}
					if (line.has_prefix("email_package: ")) {
						this.email_package = line.substring(15).strip();
						continue;
					}
				}
				dis.close();
			} catch (Error e) {
			}
		}

		public void write_defaults() {

			var file = File.new_for_path(Path.build_filename(GLib.Environment.get_home_dir(),".config","autovala"));
			if (!file.query_exists()) {
				file.make_directory_with_parents();
			}
			file = File.new_for_path(Path.build_filename(GLib.Environment.get_home_dir(),".config","autovala","packages.cfg"));
			if (file.query_exists()) {
				file.delete();
			}
			try {
				var dis = file.create_readwrite(GLib.FileCreateFlags.PRIVATE);
				var of = new DataOutputStream(dis.output_stream as FileOutputStream);
				if (this.author_package != null) {
					of.put_string("author_package: %s\n".printf(this.author_package));
				}
				if (this.email_package != null) {
					of.put_string("email_package: %s\n".printf(this.email_package));
				}
				dis.close();
			} catch (Error e) {
			}
		}

		private string cut_lines(string text, int columns) {

			var lines = text.split("\n");
			string final_text = "";

			foreach (var line in lines) {
				final_text += this.cut_line(line,columns)+"\n";
			}
			return final_text;
		}

		private string cut_line(string text, int columns) {

			string final_text = "";
			string tmp2 = "";

			int pos1;
			int pos2;
			int size = 0;
			int size2;
			int current_offset = 0;

			while(true) {
				pos1 = text.index_of_char(' ',current_offset);
				if (pos1 == -1) {
					if (size != 0) {
						final_text += tmp2+" ";
					}
					final_text += text.substring(current_offset);
					break;
				}
				size2 = pos1-current_offset;
				if (size != 0) {
					if (size+size2+1 < columns) {
						tmp2 += " "+text.substring(current_offset,size2);
						size += size2+1;
					} else {
						final_text += tmp2+"\n";
						tmp2 = "";
						size = 0;
					}
				}
				if (size == 0) {
					tmp2 = text.substring(current_offset,size2);
					size = size2;
				}
				current_offset += size2+1;
			}
			return final_text;
		}

		private bool read_description(string path) {

			string[] content = {};

			var file = File.new_for_path(path);
			if (!file.query_exists()) {
				return false;
			}
			try {
				var dis = new DataInputStream (file.read ());
				string line;
				while ((line = dis.read_line (null)) != null) {
					content+=line;
				}
			} catch (Error e) {
				return false;
			}

			string? last_line = null;
			string[] newcontent = {};
			// Replace double-line markdown elements with single-line ones
			foreach(var line in content) {
				if (this.check_line_has_single_char(line)) {
					if (last_line != null) {
						newcontent += "# "+last_line;
						last_line = null;
					}
				} else {
					if (last_line != null) {
						newcontent += last_line;
					}
					last_line = line;
				}
			}
			if (last_line != null) {
				newcontent += last_line;
			}

			// Now take only the first part in the markdown text

			bool started = false;
			string[] descr = {};
			foreach(var line in newcontent) {
				if (line.length == 0) {
					if (started) {
						descr+="";
					}
					continue;
				}
				if (line[0] == '#') {
					if (started) {
						break;
					} else {
						started = true;
					}
				} else {
					started = true;
					descr+=line;
				}
			}

			if (descr.length != 0) {
				string text = "";
				bool with_spaces = false;
				bool after_cr = true;
				foreach(var line in descr) {
					if (line != "") {
						if ((line[0] == ' ') || (line[0] == '\t')) {
							var tmpline = line.strip();
							if (tmpline == "") {
								text += "\n";
								after_cr = true;
								continue;
							}
							if (tmpline[0] == '*') {
								if (!after_cr) {
									text += "\n";
									after_cr = true;
								}
							} else {
								text += " "+tmpline;
								after_cr = false;
								continue;
							}
						}
						if (!after_cr) {
							text += " ";
						}
						text += line;
						after_cr = false;
					} else {
						if (!after_cr) {
							text += "\n\n";
						}
						after_cr = true;
					}
				}
				this.description = text.strip();

			}
			return true;
		}

		private bool check_line_has_single_char(string line) {
			if (line.length == 0) {
				return false;
			}
			var character = line[0];
			if ((character != '=') && (character != '-')) {
				return false;
			}
			int c;
			for(c=0; c < line.length; c++) {
				if (line[c]!=character) {
					return false;
				}
			}
			return true;
		}
	}
}
