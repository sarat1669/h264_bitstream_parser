require 'tempfile'
require 'posix/spawn'

def run_cmd_with_response(cmd, return_exit_code=false)
  include POSIX::Spawn
  raw_response = `#{cmd}`
  successful = true
  exit_status = $?.exitstatus
  if exit_status != 0
    puts "cmd failed: \n#{raw_response}"
    successful = false
  end

  return exit_status, raw_response if return_exit_code
  return successful, raw_response
end

def get_video_scan_type(asset_path)
  basename = File.basename(asset_path, ".ts")
  temp_file = Tempfile.new(["#{basename}", ".h264"])

  success, response = nil, nil
  command = "ffmpeg -y -i #{asset_path} -vcodec copy #{temp_file.path} 2>&1"
  response = ""
  exit_status = -1

  exit_status, response = run_cmd_with_response(command, true)

  unless exit_status == 0
    puts "Ffmpeg failed with code #{exit_status}, #{response}"
    temp_file.unlink
    return false
  end

  h264_analyze_response = Tempfile.new(["#{basename}", ".txt"])
  exit_status = -1
  command = "./h264_analyze #{temp_file.path} > #{h264_analyze_response.path}"

  exit_status, response = run_cmd_with_response(command, true)

  unless exit_status == 0
    puts "h264_analyze failed with code #{exit_status}, #{response}"
    temp_file.unlink
    h264_analyze_response.unlink
    return false
  end

  frame_mbs_only_flag_1_count = 0
  field_pic_flag_count = 0
  mb_adaptive_frame_field_flag_count = 0
  field_order_entries = []

  File.open(h264_analyze_response,'r').each_line do |line|
    frame_mbs_only_flag_1_count += line.scan(/frame_mbs_only_flag\s*:\s*1/).length
    field_pic_flag_count += line.scan(/field_pic_flag\s*:\s*1/).length
    mb_adaptive_frame_field_flag_count += line.scan(/mb_adaptive_frame_field_flag\s*:\s*1/).length
    field_order_entries.concat line.scan(/bottom_field_flag\s*:\s*.*/)
  end

  # At least one of the flags will be present in the h264 bitstream or else the input is invalid
  return false, "Unable to determine scan type." if frame_mbs_only_flag_1_count == 0 and field_pic_flag_count == 0 and mb_adaptive_frame_field_flag_count == 0
  is_mbaff = false
  # Scan type is progressive if frame_mbs_only_flag is set to 1
  if frame_mbs_only_flag_1_count > 0
    # field_pic_flag and mb_adaptive_frame_field_flag should not be set to 1 if progressive
    if mb_adaptive_frame_field_flag_count == 0 and field_pic_flag_count == 0
      scan_type = "progressive"
    else
      scan_type = "mixed"
    end
  else
    # If mb_adaptive_frame_field_flag is set to 1, and the rest of the flags are 0, the scan type is interlaced and MBAFF encoded
    if mb_adaptive_frame_field_flag_count > 0 and field_pic_flag_count == 0
      scan_type = "interlaced_mbaff"
      # If field_pic_flag is set to 1 and all other flags are 0, the scan type is interlaced
    elsif field_pic_flag_count > 0 and mb_adaptive_frame_field_flag_count == 0
      scan_type = "interlaced"
    else
      scan_type = "mixed"
    end
  end

  if scan_type =~ /interlaced/
    invalid = false
    last = nil
    # According to ITU-T h264 specification, if bottom_field_flag is not present, it should be considered as `bottom_field_flag: 0` (top_field_first field_order)
    if field_order_entries.length > 0
      field_order = field_order_entries.first.split(':').last.to_i == 0 ? 'top_field_first' : 'bottom_field_first'
      field_order_entries.each do |field|
        current = field.split(':').last.to_i
        invalid = true and break if current == last unless last.nil?
        last = current
      end
      field_order = "mixed" if invalid
    else
      field_order = "top_field_first"
    end
  end

  temp_file.unlink
  h264_analyze_response.unlink
  puts "scan_type: #{scan_type}"
  puts "field_order: #{field_order}" if scan_type == "interlaced"
  return true, scan_type, field_order
end

get_video_scan_type(ARGV[0])
