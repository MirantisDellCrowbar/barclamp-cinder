# Copyright 2012, Dell Inc. 
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 

class CinderController < BarclampController
  def initialize
    @service_object = CinderService.new logger
  end

  def node_disks
    name = params[:id] || params[:name]
    node = NodeObject.find_node_by_name(name)

    result = {
        "node" => name,
        "alias" => node["crowbar"]["display"]["alias"],
        "disks" => {}
    }

    node["crowbar"]["disks"].each do | disk, data |
      result["disks"][disk] = data["size"] if data["usage"] == "Storage"
    end
    Rails.logger.info "disk list #{result.inspect}"
    render :json => JSON.generate(result)
    end
end

