#!/usr/bin/env bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

naive_systemd_version="${1:-latest}"
naive_docker_version=":${naive_systemd_version#v}"
naive_docker_image="ghcr.io/jonssonyan/naive"

init_var() {
  ECHO_TYPE="echo -e"

  package_manager=""
  release=""
  version=""
  get_arch=""

  NAIVE_DATA_DOCKER="/naive/"
  NAIVE_DATA_SYSTEMD="/usr/local/naive/"

  naive_config_docker="/naive/config/naive.json"
  naive_config_systemd="/usr/local/naive/naive.json"

  naive_ssl_method=1
  naive_domain=""
  naive_email=""
  naive_ssl=1
  naive_crt=""
  naive_key=""

  naive_port=444
  naive_username="sysadmin"
  naive_password="sysadmin"
  naive_auth=""
}

echo_content() {
  case $1 in
  "red")
    ${ECHO_TYPE} "\033[31m$2\033[0m"
    ;;
  "green")
    ${ECHO_TYPE} "\033[32m$2\033[0m"
    ;;
  "yellow")
    ${ECHO_TYPE} "\033[33m$2\033[0m"
    ;;
  "blue")
    ${ECHO_TYPE} "\033[34m$2\033[0m"
    ;;
  "purple")
    ${ECHO_TYPE} "\033[35m$2\033[0m"
    ;;
  "skyBlue")
    ${ECHO_TYPE} "\033[36m$2\033[0m"
    ;;
  "white")
    ${ECHO_TYPE} "\033[37m$2\033[0m"
    ;;
  esac
}

can_connect() {
  if ping -c2 -i0.3 -W1 "$1" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

version_ge() {
  local v1=${1#v}
  local v2=${2#v}

  if [[ -z "$v1" || "$v1" == "latest" ]]; then
    return 0
  fi

  IFS='.' read -r -a v1_parts <<<"$v1"
  IFS='.' read -r -a v2_parts <<<"$v2"

  for i in "${!v1_parts[@]}"; do
    local part1=${v1_parts[i]:-0}
    local part2=${v2_parts[i]:-0}

    if [[ "$part1" < "$part2" ]]; then
      return 1
    elif [[ "$part1" > "$part2" ]]; then
      return 0
    fi
  done
  return 0
}

check_sys() {
  if [[ $(id -u) != "0" ]]; then
    echo_content red "You must be root to run this script"
    exit 1
  fi

  can_connect www.google.com
  if [[ "$?" == "1" ]]; then
    echo_content red "---> Network connection failed"
    exit 1
  fi

  if [[ $(command -v yum) ]]; then
    package_manager='yum'
  elif [[ $(command -v dnf) ]]; then
    package_manager='dnf'
  elif [[ $(command -v apt-get) ]]; then
    package_manager='apt-get'
  elif [[ $(command -v apt) ]]; then
    package_manager='apt'
  fi

  if [[ -z "${package_manager}" ]]; then
    echo_content red "This system is not currently supported"
    exit 1
  fi

  if [[ -n $(find /etc -name "redhat-release") ]] || grep </proc/version -q -i "centos"; then
    release="centos"
    if rpm -q centos-stream-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-stream-release)
    elif rpm -q centos-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-release)
    fi
  elif grep </etc/issue -q -i "debian" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "debian" && [[ -f "/proc/version" ]]; then
    release="debian"
    version=$(cat /etc/debian_version)
  elif grep </etc/issue -q -i "ubuntu" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "ubuntu" && [[ -f "/proc/version" ]]; then
    release="ubuntu"
    version=$(lsb_release -sr)
  fi

  major_version=$(echo "${version}" | cut -d. -f1)

  case $release in
  centos)
    if [[ $major_version -ge 6 ]]; then
      echo_content green "Supported CentOS version detected: $version"
    else
      echo_content red "Unsupported CentOS version: $version. Only supports CentOS 6+."
      exit 1
    fi
    ;;
  ubuntu)
    if [[ $major_version -ge 16 ]]; then
      echo_content green "Supported Ubuntu version detected: $version"
    else
      echo_content red "Unsupported Ubuntu version: $version. Only supports Ubuntu 16+."
      exit 1
    fi
    ;;
  debian)
    if [[ $major_version -ge 8 ]]; then
      echo_content green "Supported Debian version detected: $version"
    else
      echo_content red "Unsupported Debian version: $version. Only supports Debian 8+."
      exit 1
    fi
    ;;
  *)
    echo_content red "Only supports CentOS 6+/Ubuntu 16+/Debian 8+"
    exit 1
    ;;
  esac

  if [[ $(arch) =~ ("x86_64"|"amd64") ]]; then
    get_arch="amd64"
  elif [[ $(arch) =~ ("aarch64"|"arm64") ]]; then
    get_arch="arm64"
  fi

  if [[ -z "${get_arch}" ]]; then
    echo_content red "Only supports x86_64/amd64 arm64/aarch64"
    exit 1
  fi
}

install_depend() {
  if [[ "${package_manager}" == 'apt-get' || "${package_manager}" == 'apt' ]]; then
    ${package_manager} update -y
  fi
  ${package_manager} install -y \
    curl \
    systemd \
    nftables
}

setup_docker() {
  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  }
}
EOF
  systemctl daemon-reload
}

install_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content green "---> Install Docker"

    bash <(curl -fsSL https://get.docker.com)

    setup_docker

    systemctl enable docker && systemctl restart docker

    if [[ $(command -v docker) ]]; then
      echo_content skyBlue "---> Docker install successful"
    else
      echo_content red "---> Docker install failed"
      exit 1
    fi
  else
    echo_content skyBlue "---> Docker is already installed"
  fi
}

set_naive_auto() {
  echo_content yellow "Tip: Please confirm that the domain name has been resolved to this machine, otherwise the installation may fail"
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  read -r -p "Please enter your email (optional): " naive_email

  while read -r -p "Please choose the way to apply for the certificate (1/acme 2/zerossl default: 1: " naive_ssl_type; do
    if [[ -z "${naive_ssl_type}" || ${naive_ssl_type} == 1 ]]; then
      naive_ssl="acme"
      break
    elif [[ ${naive_ssl_type} == 2 ]]; then
      naive_ssl="zerossl"
      break
    else
      echo_content red "Cannot enter other characters except 1 and 2"
    fi
  done

  cat >${naive_config_systemd} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_SYSTEMD}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": [
                            "${naive_auth}"
                          ],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_SYSTEMD}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": [
          "${naive_domain}"
        ]
      },
      "automation": {
        "policies": [
          {
            "issuers": [
              {
                "module": "${naive_ssl}",
                "email": "${naive_email}"
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
}

set_naive_auto_lt276() {
  echo_content yellow "Tip: Please confirm that the domain name has been resolved to this machine, otherwise the installation may fail"
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  read -r -p "Please enter your email (optional): " naive_email

  while read -r -p "Please choose the way to apply for the certificate (1/acme 2/zerossl default: 1: " naive_ssl_type; do
    if [[ -z "${naive_ssl_type}" || ${naive_ssl_type} == 1 ]]; then
      naive_ssl="acme"
      break
    elif [[ ${naive_ssl_type} == 2 ]]; then
      naive_ssl="zerossl"
      break
    else
      echo_content red "Cannot enter other characters except 1 and 2"
    fi
  done

  cat >${naive_config_systemd} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_SYSTEMD}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_pass_deprecated": "${naive_username}",
                          "auth_user_deprecated": "${naive_password}",
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_SYSTEMD}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": [
          "${naive_domain}"
        ]
      },
      "automation": {
        "policies": [
          {
            "issuers": [
              {
                "module": "${naive_ssl}",
                "email": "${naive_email}"
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
}

set_naive_custom() {
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the crt path of naive (required): " naive_crt; do
    if [[ -z "${naive_crt}" ]]; then
      echo_content red "crt path cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the key path of naive (required): " naive_key; do
    if [[ -z "${naive_key}" ]]; then
      echo_content red "key path cannot be empty"
    else
      break
    fi
  done

  cat >${naive_config_systemd} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_SYSTEMD}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": [
                            "${naive_auth}"
                          ],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_SYSTEMD}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "${naive_crt}",
            "key": "${naive_key}"
          }
        ]
      }
    }
  }
}
EOF
}

set_naive_custom_lt276() {
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the crt path of naive (required): " naive_crt; do
    if [[ -z "${naive_crt}" ]]; then
      echo_content red "crt path cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the key path of naive (required): " naive_key; do
    if [[ -z "${naive_key}" ]]; then
      echo_content red "key path cannot be empty"
    else
      break
    fi
  done

  cat >${naive_config_systemd} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_SYSTEMD}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_pass_deprecated": "${naive_username}",
                          "auth_user_deprecated": "${naive_password}",
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_SYSTEMD}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "${naive_crt}",
            "key": "${naive_key}"
          }
        ]
      }
    }
  }
}
EOF
}

set_naive() {
  read -r -p "Please enter the port of naive (default: 444): " naive_port
  [[ -z "${naive_port}" ]] && naive_port="444"

  read -r -p "Please enter the username of naive (default: sysadmin): " naive_username
  [[ -z "${naive_username}" ]] && naive_username="sysadmin"
  read -r -p "Please enter the password of naive (default: sysadmin): " naive_password
  [[ -z "${naive_password}" ]] && naive_password="sysadmin"
  naive_auth=$(echo -n "${naive_username}:${naive_password}" | base64 | tr --delete '\n' | base64)

  while read -r -p "Please select the management certificate method(1/auto 2/custom default: 1): " naive_ssl_method; do
    if [[ -z "${naive_ssl_method}" || ${naive_ssl_method} == 1 ]]; then
      if version_ge "${naive_systemd_version}" "v2.7.6"; then
        set_naive_auto
      else
        set_naive_auto_lt276
      fi
      break
    elif [[ ${naive_ssl_method} == 2 ]]; then
      if version_ge "${naive_systemd_version}" "v2.7.6"; then
        set_naive_custom
      else
        set_naive_custom_lt276
      fi
      break
    else
      echo_content red "Cannot enter other characters except 1 and 2"
    fi
  done
}

install_naive_systemd() {
  if systemctl list-units --type=service --all | grep -q 'naive.service'; then
    echo_content skyBlue "---> naive is already installed"
    exit 0
  fi

  echo_content green "---> Install naive"
  mkdir -p ${NAIVE_DATA_SYSTEMD}
  mkdir -p ${NAIVE_DATA_SYSTEMD}html/

  cat >${NAIVE_DATA_SYSTEMD}html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
EOF

  set_naive

  bin_url=https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-${get_arch}
  if [[ "latest" != "${naive_systemd_version}" ]]; then
    bin_url=https://github.com/jonssonyan/naive/releases/download/${naive_systemd_version}/naive-linux-${get_arch}
  fi

  curl -fsSL "${bin_url}" -o /usr/local/naive/naive &&
    chmod +x /usr/local/naive/naive &&
    curl -fsSL https://raw.githubusercontent.com/jonssonyan/naive/main/naive.service -o /etc/systemd/system/naive.service &&
    sed -i "s|^ExecStart=.*|ExecStart=/usr/local/naive/naive run --config ${naive_config_systemd}|" "/etc/systemd/system/naive.service" &&
    systemctl daemon-reload &&
    systemctl enable naive &&
    systemctl restart naive
  echo_content skyBlue "---> naive install successful"
}

upgrade_naive_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'naive.service'; then
    echo_content red "---> naive not installed"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/jonssonyan/naive/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(/usr/local/naive/naive version | awk '{print $1}')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> naive is already the latest version"
    exit 0
  fi

  echo_content green "---> Upgrade naive"
  if [[ $(systemctl is-active naive) == "active" ]]; then
    systemctl stop naive
  fi

  bin_url=https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-${get_arch}
  if ! version_ge "${current_version}" "v2.7.6"; then
    bin_url=https://github.com/jonssonyan/naive/releases/download/v2.7.5/naive-linux-${get_arch}
  fi

  curl -fsSL "${bin_url}" -o /usr/local/naive/naive &&
    chmod +x /usr/local/naive/naive &&
    systemctl restart naive
  echo_content skyBlue "---> naive upgrade successful"
}

uninstall_naive_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'naive.service'; then
    echo_content red "---> naive not installed"
    exit 0
  fi

  echo_content green "---> Uninstall naive"
  if [[ $(systemctl is-active naive) == "active" ]]; then
    systemctl stop naive
  fi
  systemctl disable naive.service &&
    rm -f /etc/systemd/system/naive.service &&
    systemctl daemon-reload &&
    rm -rf /usr/local/naive/ &&
    systemctl reset-failed
  echo_content skyBlue "---> naive uninstall successful"
}

set_naive_docker_auto() {
  echo_content yellow "Tip: Please confirm that the domain name has been resolved to this machine, otherwise the installation may fail"
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  read -r -p "Please enter your email (optional): " naive_email

  while read -r -p "Please choose the way to apply for the certificate (1/acme 2/zerossl default: 1: " naive_ssl_type; do
    if [[ -z "${naive_ssl_type}" || ${naive_ssl_type} == 1 ]]; then
      naive_ssl="acme"
      break
    elif [[ ${naive_ssl_type} == 2 ]]; then
      naive_ssl="zerossl"
      break
    else
      echo_content red "Cannot enter other characters except 1 and 2"
    fi
  done

  cat >${naive_config_docker} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_DOCKER}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": [
                            "${naive_auth}"
                          ],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_DOCKER}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": [
          "${naive_domain}"
        ]
      },
      "automation": {
        "policies": [
          {
            "issuers": [
              {
                "module": "${naive_ssl}",
                "email": "${naive_email}"
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
}

set_naive_docker_auto_lt276() {
  echo_content yellow "Tip: Please confirm that the domain name has been resolved to this machine, otherwise the installation may fail"
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  read -r -p "Please enter your email (optional): " naive_email

  while read -r -p "Please choose the way to apply for the certificate (1/acme 2/zerossl default: 1: " naive_ssl_type; do
    if [[ -z "${naive_ssl_type}" || ${naive_ssl_type} == 1 ]]; then
      naive_ssl="acme"
      break
    elif [[ ${naive_ssl_type} == 2 ]]; then
      naive_ssl="zerossl"
      break
    else
      echo_content red "Cannot enter other characters except 1 and 2"
    fi
  done

  cat >${naive_config_docker} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_DOCKER}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_pass_deprecated": "${naive_username}",
                          "auth_user_deprecated": "${naive_password}",
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_DOCKER}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": [
          "${naive_domain}"
        ]
      },
      "automation": {
        "policies": [
          {
            "issuers": [
              {
                "module": "${naive_ssl}",
                "email": "${naive_email}"
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
}

set_naive_docker_custom() {
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the crt path of naive (required): " naive_crt; do
    if [[ -z "${naive_crt}" ]]; then
      echo_content red "crt path cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the key path of naive (required): " naive_key; do
    if [[ -z "${naive_key}" ]]; then
      echo_content red "key path cannot be empty"
    else
      break
    fi
  done

  cat >${naive_config_docker} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_DOCKER}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": [
                            "${naive_auth}"
                          ],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_DOCKER}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "${naive_crt}",
            "key": "${naive_key}"
          }
        ]
      }
    }
  }
}
EOF
}

set_naive_docker_custom_lt276() {
  while read -r -p "Please enter your domain name (required): " naive_domain; do
    if [[ -z "${naive_domain}" ]]; then
      echo_content red "Domain name cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the crt path of naive (required): " naive_crt; do
    if [[ -z "${naive_crt}" ]]; then
      echo_content red "crt path cannot be empty"
    else
      break
    fi
  done

  while read -r -p "Please enter the key path of naive (required): " naive_key; do
    if [[ -z "${naive_key}" ]]; then
      echo_content red "key path cannot be empty"
    else
      break
    fi
  done

  cat >${naive_config_docker} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage":{
      "module":"file_system",
      "root":"${NAIVE_DATA_DOCKER}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_pass_deprecated": "${naive_username}",
                          "auth_user_deprecated": "${naive_password}",
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_DOCKER}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "${naive_crt}",
            "key": "${naive_key}"
          }
        ]
      }
    }
  }
}
EOF
}

set_naive_docker() {
  read -r -p "Please enter the port of naive (default: 444): " naive_port
  [[ -z "${naive_port}" ]] && naive_port="444"

  read -r -p "Please enter the username of naive (default: sysadmin): " naive_username
  [[ -z "${naive_username}" ]] && naive_username="sysadmin"
  read -r -p "Please enter the password of naive (default: sysadmin): " naive_password
  [[ -z "${naive_password}" ]] && naive_password="sysadmin"
  naive_auth=$(echo -n "${naive_username}:${naive_password}" | base64 | base64)

  while read -r -p "Please select the management certificate method(1/auto 2/custom default: 1): " naive_ssl_method; do
    if [[ -z "${naive_ssl_method}" || ${naive_ssl_method} == 1 ]]; then
      if version_ge "${naive_systemd_version}" "v2.7.6"; then
        set_naive_docker_auto
      else
        set_naive_docker_auto_lt276
      fi
      break
    elif [[ ${naive_ssl_method} == 2 ]]; then
      if version_ge "${naive_systemd_version}" "v2.7.6"; then
        set_naive_docker_custom
      else
        set_naive_docker_custom_lt276
      fi
      break
    else
      echo_content red "Cannot enter other characters except 1 and 2"
    fi
  done
}

install_naive_docker() {
  if [[ -n $(docker ps -a -q -f "name=^naive$") ]]; then
    echo_content skyBlue "---> naive is already installed"
    exit 0
  fi

  echo_content green "---> Install naive"
  mkdir -p ${NAIVE_DATA_DOCKER}
  mkdir -p ${NAIVE_DATA_DOCKER}html/
  mkdir -p ${NAIVE_DATA_DOCKER}config/

  cat >${NAIVE_DATA_DOCKER}html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
EOF

  set_naive_docker

  docker pull "${naive_docker_image}${naive_docker_version}" &&
    docker run -d \
      --name naive --restart always \
      --network=host \
      -v /naive/html/:/naive/html/ \
      -v /naive/config/:/naive/config/ \
      "${naive_docker_image}${naive_docker_version}" \
      ./naive run --config ${naive_config_docker}
  echo_content skyBlue "---> naive install successful"
}

upgrade_naive_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> Docker not installed"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^naive$") ]]; then
    echo_content red "---> naive not installed"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/jonssonyan/naive/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(docker exec naive ./naive version | awk '{print $1}')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> naive is already the latest version"
    exit 0
  fi

  echo_content green "---> Upgrade naive"
  docker rm -f naive
  docker images "${naive_docker_image}" -q | xargs -r docker rmi -f

  docker pull "${naive_docker_image}:latest" &&
    docker run -d \
      --name naive --restart always \
      --network=host \
      -v /naive/html/:/naive/html/ \
      -v /naive/config/:/naive/config/ \
      "${naive_docker_image}:latest" \
      ./naive run --config ${naive_config_docker}
  echo_content skyBlue "---> naive upgrade successful"
}

uninstall_naive_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> Docker not installed"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^naive$") ]]; then
    echo_content red "---> naive not installed"
    exit 0
  fi

  echo_content green "---> Uninstall naive"
  docker rm -f naive
  docker images "${naive_docker_image}" -q | xargs -r docker rmi -f
  rm -rf /naive/
  echo_content skyBlue "---> naive uninstall successful"
}

main() {
  cd "$HOME" || exit 0
  init_var
  check_sys
  install_depend
  clear
  echo_content red "\n=============================================================="
  echo_content skyBlue "Recommended OS: CentOS 8+/Ubuntu 20+/Debian 11+"
  echo_content skyBlue "Description: Quick Installation of naive"
  echo_content skyBlue "Author: jonssonyan <https://jonssonyan.com>"
  echo_content skyBlue "Github: https://github.com/jonssonyan/naive"
  echo_content red "\n=============================================================="
  echo_content yellow "1. Install naive (systemd)"
  echo_content yellow "2. Upgrade naive (systemd)"
  echo_content yellow "3. Uninstall naive (systemd)"
  echo_content red "\n=============================================================="
  echo_content yellow "4. Install naive (Docker)"
  echo_content yellow "5. Upgrade naive (Docker)"
  echo_content yellow "6. Uninstall naive (Docker)"
  read -r -p "Please choose: " input_option
  case ${input_option} in
  1)
    install_naive_systemd
    ;;
  2)
    upgrade_naive_systemd
    ;;
  3)
    uninstall_naive_systemd
    ;;
  4)
    install_docker
    install_naive_docker
    ;;
  5)
    upgrade_naive_docker
    ;;
  6)
    uninstall_naive_docker
    ;;
  *)
    echo_content red "No such option"
    ;;
  esac
}

main
