cd ScriptGeneratingAgent/agents
dotnet new console -n ScriptGeneratorAgent
dotnet add package Microsoft.Data.SqlClient
dotnet add package System.Text.Json
dotnet build
dotnet run -- ../Backend