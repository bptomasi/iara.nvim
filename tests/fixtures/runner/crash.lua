-- Exits while being collected, so its process writes no report.
io.stderr:write("crash fixture exiting\n")
os.exit(3)
