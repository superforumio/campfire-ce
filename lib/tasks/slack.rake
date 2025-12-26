namespace :slack do
  desc "Import Slack export from ZIP file"
  task :import, [ :zip_path ] => :environment do |t, args|
    zip_path = args[:zip_path]

    unless zip_path.present?
      puts "ERROR: Please provide a path to the Slack export ZIP file"
      puts "Usage: bin/rails slack:import[/path/to/export.zip]"
      exit 1
    end

    unless File.exist?(zip_path)
      puts "ERROR: File not found: #{zip_path}"
      exit 1
    end

    puts "Starting Slack import from: #{zip_path}"

    importer = SlackImporter.new(zip_path)
    stats = importer.import!

    puts ""
    puts "IMPORT_COMPLETE"
    puts "IMPORT_STATS:#{stats.to_json}"
  end
end
