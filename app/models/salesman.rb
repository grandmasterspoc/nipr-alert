# == Schema Information
#
# Table name: salesmen
#
#  id                  :integer          not null, primary key
#  npn                 :string(255)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  position_id         :string(255)
#  first_name          :string(255)
#  last_name           :string(255)
#  associate_oid       :string(255)
#  associate_id        :string(255)
#  adp_position_id     :string(255)
#  job_title           :string(255)
#  department_name     :string(255)
#  department_id       :string(255)
#  agent_indicator     :integer
#  hire_date           :date
#  position_start_date :date
#  class_start_date    :date
#  class_end_date      :date
#  trainer             :string(255)
#  uptraining_class    :string(255)
#  compliance_status   :integer
#  deleted             :integer
#  agent_supervisor    :string(255)
#  pod                 :string(255)
#  agent_site          :string(255)
#  client              :string(255)
#  username            :string(255)
#  cxp_employee_id     :string(255)


require 'csv'
require 'roo'
require 'roo-xls'
require 'net/ssh'
require 'open-uri'

class Salesman < ApplicationRecord
  has_many :states
  has_many :state_agent_appointeds

  filterrific :default_filter_params => {sorted_by: 'created_at_desc' },
              available_filters:[
                :sorted_by,
                :search_query,
                :with_created_at_gte
              ]


  scope :search_query, lambda { |query|
    return nil  if query.blank?
    # condition query, parse into individual keywords
    terms = query.to_s.downcase.split(/\s+/)
    # replace "*" with "%" for wildcard searches,
    # append '%', remove duplicate '%'s
    terms = terms.map { |e|
      (e.gsub('*', '%') + '%').gsub(/%+/, '%')
    }
    # configure number of OR conditions for provision
    # of interpolation arguments. Adjust this if you
    # change the number of OR conditions.
    num_or_conditions = 5
    where(
      terms.map {
        or_clauses = [
          "LOWER(salesmen.first_name) LIKE ?",
          "LOWER(salesmen.last_name) LIKE ?",
          "LOWER(salesmen.agent_supervisor) LIKE ?",
          "LOWER(salesmen.agent_site) LIKE ?",
          "LOWER(salesmen.npn) LIKE ?"
        ].join(' OR ')
        "(#{ or_clauses })"
      }.join(' AND '),
      *terms.map { |e| [e] * num_or_conditions }.flatten
    )
  }

  scope :with_created_at_gte, lambda { |ref_date|
    where('salesmen.position_start_date >= ?', ref_date)
    # where('salesmen.position_start_date BETWEEN ? AND ?', ref_date1, ref_date2)
  }

  scope :sorted_by, lambda { |sort_option|
      # extract the sort direction from the param value.
      direction = (sort_option =~ /desc$/) ? 'desc' : 'asc'
      case sort_option.to_s
      when /^created_at_/
        order("salesmen.created_at #{ direction }")
      when /^position_start_date_/
        order("salesmen.position_start_date #{ direction }")
      when /^last_name_/
        order("LOWER(salesmen.last_name) #{ direction }, LOWER(salesmen.first_name) #{ direction }")
      when /^first_name_/
        order("LOWER(salesmen.first_name) #{ direction }")
      when /^site_/
        order("LOWER(salesmen.site) #{ direction }")
      else
        raise(ArgumentError, "Invalid sort option: #{ sort_option.inspect }")
      end
    }

    def self.options_for_sorted_by
      [
        ['First Name (a-z)', 'first_name_asc'],
        ['Last Name (a-z)', 'last_name_asc'],
        ['Hire date (newest first)', 'created_at_desc'],
        ['Hire date (oldest first)', 'created_at_asc'],
      ]
    end

  def self.search(column)
    unless search[:column] == ''
      where("#{search[:column]} LIKE ?", "%#{search}")
    else
      scoped
    end
  end

  def api_path
    "https://pdb-services.nipr.com/pdb-xml-reports/entityinfo_xml.cgi?customer_number=dcortez&pin_number=p3anutpingpong&report_type=1&id_entity=#{self.npn}"
  end

  def grab_info
    res = open(api_path)
    data = Hash.from_xml(res.read)
    return data
  end

  def update_npn_and_get_data(npn)
    self.update(npn: npn)
    update_states_licensing_info
  end

  def update_states_licensing_info
    data = grab_info
    update_name_if_nil(data)
    all_states = data["PDB"]['PRODUCER']['INDIVIDUAL']["PRODUCER_LICENSING"]["LICENSE_INFORMATION"]["STATE"]
    all_states.each do |state_info|
      db_state = self.states.find_or_create_by(name: state_info["name"])
      db_state.save!
      save_states_data(db_state, state_info)
    end
  end

  def save_states_data(state, state_info)
    save_licensing_info(state, state_info["LICENSE"])
    save_appointment_info(state, state_info["APPOINTMENT_INFORMATION"]["APPOINTMENT"])
  end

  def save_licensing_info(state, state_info)
    s_info = downcased(state_info) unless s_info.is_a?(Array)
    unless s_info == nil
      license_info = s_info.except("details")
      license = state.licenses.find_or_create_by(license_num: s_info['license_info'], salesman_id: self.id)
      license_info["date_updated"] = Date.strptime(license_info["date_updated"], "%m/%d/%Y") unless license_info["date_updated"] == nil
      license_info["date_issue_license_orig"] = Date.strptime(license_info["date_issue_license_orig"], "%m/%d/%Y") unless license_info["date_issue_license_orig"] == nil
      license_info["date_expire_license"] = Date.strptime(license_info["date_expire_license"], "%m/%d/%Y") unless license_info["date_expire_license"] == nil
      license.update!(license_info)
      license.save!
      save_license_details(license, [s_info["details"]["DETAIL"]].flatten)
    end
  end

  def save_license_details(license, info)
    info.each do |i|
      unless i.is_a?(Array)
        license_details = downcased(i)
        deet = license.state_details.find_or_create_by(loa: license_details["loa"])
        deet.update(license_details)
      end
    end
  end

  def save_appointment_info(state, state_info)
    state_info.each do |appt|
      unless appt.is_a?(Array)
        reformatted_state_info = downcased(appt)
        st = state.appointments.find_or_create_by(company_name: reformatted_state_info["company_name"])
        st.update(reformatted_state_info)
      end
    end
  end

  def downcased(data_hash)
    unless data_hash.is_a?(Array)
      new_hash = {}
      data_hash.keys.each do |k|
        new_hash[k.downcase] = data_hash[k]
      end
      new_hash
    end
  end

  def get_name_info(biographic_data)
    {first_name: biographic_data["NAME_FIRST"].titleize, last_name: biographic_data["NAME_LAST"].titleize}
  end

  def update_name_if_nil(data)
    if first_name == nil
      name_info = get_name_info(data["PDB"]['PRODUCER']['INDIVIDUAL']["ENTITY_BIOGRAPHIC"]["BIOGRAPHIC"])
      self.update(name_info)
    end
  end

  def self.read_csv
    csv_data = CSV.read("#{Rails.root}/../../Downloads/adp_sample_data.csv")
    all_data_as_array_of_hashes, data_types = [], csv_data.shift
    csv_data.each do |row|
      all_data_as_array_of_hashes << self.reformat_row_to_hash(row, data_types)
    end
    all_data_as_array_of_hashes
  end

  def self.reformat_row_to_hash(row, data_types)
    hashie = {}
    row.each_with_index do |item, row_index|
      unless data_types[row_index] == 'created' || data_types[row_index] == 'last_updated'
        hashie["#{data_types[row_index]}"] = item
      end
    end
    hashie
  end

  def self.save_csv_data(data_hash_array)
    self.create!(data_hash_array)
  end

  def self.get_employee_data_and_save
    data_hash_array = self.read_csv
    self.save_csv_data(data_hash_array)
  end

  def self.get_data_from_sandbox_reporting
    @hostname, @username, @password  = "aurora-ods.cluster-clc62ue6re4n.us-west-2.rds.amazonaws.com", "sgautam", "6N1J$rCFU(PxmU[I"
    connect_to_db = "mysql -u root"
    open_up_table = 'USE Sandbox_Reporting'
    sql = "Select * from stag_adp_employeeinfo"
    sql2 = "Select * from stag_agent_appointed"
    Net::SSH.start($hostname, $user_name, :password => $pass_word) do |ssh|

     ssh.exec!("#{connect_to_db}")
     stag_adp = ssh.exec!("#{sql}")
     appointment_data = ssh.exec!("#{sql2}")
    end
    ActiveRecord::Base.establish_connection(:development)
    self.save_stag_adp_employeeinfo(stag_adp.as_josn)
    self.save_aetna_appointment_data(appointment_data.as_json)
  end

  # stag_adp = external_db.execute(sql).as_json
  # appointment_data = external_db.execute(sql2).as_json
  def self.save_stag_adp_employeeinfo(stag_adp)
    stag_adp.each do |employee|
      e = self.find_by(npn: employee[:npn])
      if e.present?
        e.update!(employee)
      else
        e.create!(employee)
        e.update_states_licensing_info
      end
    end
  end

  def self.save_aetna_appointment_data(a_data)
    a_data.each do |agent|
      s = Salesman.find_or_create_by(npn: agent[:npn])
      agent.keys.each do |k|
        if k.to_s.length == 2
          Salesman.states.find_or_create_by(name: k).update(appointment_date: k)
        end
      end
    end
  end

  def self.connect_to_sandbox_reporting
    @hostname = "aurora-ods.cluster-clc62ue6re4n.us-west-2.rds.amazonaws.com"
    @username = "sgautam"
    @password = "6N1J$rCFU(PxmU[I"
    # 10.0.35.34
    ActiveRecord::Base.establish_connection(
      :adapter => 'mysql2',
      :database => 'Sandbox_Reporting',
      :host => localhost,
      :username => @username,
      :password => @password
    )
  end

  # def self.connect_to_localhost
  #   @hostname = "localhost"
  #   @username = "dilloncortez"
  #   @password = "slop3styl3"
  #   sql = "Select * from Video"
  #   # 10.0.35.34
  #   ActiveRecord::Base.establish_connection(
  #     :adapter => 'postgresql',
  #     :database => 'velvi_videos_development',
  #     :host => @hostname,
  #     :username => @username,
  #     :password => @password
  #   )
  #   # ActiveRecord::Base.connection.tables.each do |table|
  #   #   next if table.match(/\Aschema_migrations\Z/)
  #   #   klass = table.singularize.camelize.constantize
  #   #   puts "#{klass.name} has #{klass.count} records"
  #   # end
  # end

  def get_table_data
  end

  def self.get_csv_and_save_data
    array_of_data = self.read_csv
    array_of_data.each do |person|
      self.find_or_create_by(associate_oid: person["associate_oid"]).update(cxp_employee_id: person["cxp_employee_id"], username: person["username"])
    end
  end

  def self.read_csv
    csv_data = CSV.read("#{Rails.root}/../../Downloads/cXp_ID_Table.csv")
    all_data_as_array_of_hashes, data_types = [], csv_data.shift
    csv_data.each do |row|
      all_data_as_array_of_hashes << self.reformat_row_to_hash(row, data_types)
    end
    all_data_as_array_of_hashes
  end

  def self.reformat_row_to_hash(row, data_types)
    hashie = {}
    row.each_with_index do |item, row_index|
      unless data_types[row_index] == 'created' || data_types[row_index] == 'last_updated'
        hashie["#{data_types[row_index]}"] = item
      end
    end
    hashie
  end

  def add_needed_states
    self.update(jit_sites_not_appointed_in: get_needed_states.join(", "))
  end

  def get_needed_states
    all_states_names - states.all.map(&:name)
  end

  def states_needed_per_site
    {"Provo" => ["AK", "AZ", "CO", "HI", "ID", "MT", "NM", "OR", "UT", "WA", "CA", "NV", "VA", "WY"],
      "Sandy" => all_states_names,
      "Memphis" => all_states_names,
      "San Antonio" => ["AR", "ND" "IA", "KS", "NE", "OK", "SD", "TX"],
      "Sunrise" => ["AL", "LA"],
      "Sawgrass" => all_states_names
    }
  end

  def all_states_names
    ["AK",
    "AL",
    "AR",
    "AZ",
    "CA",
    "CO",
    "CT",
    "DC",
    "DE",
    "FL",
    "GA",
    "HI",
    "IA",
    "ID",
    "IL",
    "IN",
    "KS",
    "KY",
    "LA",
    "MA",
    "MD",
    "ME",
    "MI",
    "MN",
    "MO",
    "MS",
    "MT",
    "NC",
    "ND",
    "NE",
    "NH",
    "NJ",
    "NM",
    "NV",
    "NY",
    "OH",
    "OK",
    "OR",
    "PA",
    "RI",
    "SC",
    "SD",
    "TN",
    "TX",
    "UT",
    "VA",
    "VT",
    "WA",
    "WI",
    "WV",
    "WY"]
  end

  def jit_states
    ["AK",
     "AR",
     "CA",
     "CT",
     "DE",
     "DC",
     "FL",
     "GA",
     "HI",
     "ID",
     "IA",
     "KS",
     "ME",
     "MD",
     "MA",
     "MI",
     "MN",
     "MS",
     "MO",
     "NE",
     "NV",
     "NH",
     "NJ",
     "NM",
     "NY",
     "NC",
     "ND",
     "OK",
     "SC",
     "SD",
     "TN",
     "TX",
     "VA",
     "WV",
     "WY"]
  end

  def sites_with_just_in_time_states
    { "Provo" =>  jit_states,
      "Sunrise" => jit_states,
      "Sandy" => jit_states,
      "Memphis" => jit_states,
      "San Antonio" => jit_states,
      "Sawgrass" => jit_states}
  end

  def self.update_npns_from_spread_sheet
    xl = Roo::Spreadsheet.open("#{Rails.root}/npn_numbers.xls", extension: :xls)
    sheet = xl.sheet(0).to_a
    sheet.to_a.shift
    sheet.each do |row|
      unless row[3] == ""
        sman = self.find_or_create_by(npn: row[3])
        sman.update_states_licensing_info
      end
    end
    # binding.pry
  end

  def self.as
    self.update_npns_from_spread_sheet
  end

end
