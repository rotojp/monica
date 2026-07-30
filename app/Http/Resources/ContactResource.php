<?php

namespace App\Http\Resources;

use App\Helpers\DateHelper;
use App\Helpers\NameHelper;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * @mixin \App\Models\Contact
 */
class ContactResource extends JsonResource
{
    /**
     * Transform the resource into an array.
     *
     * @param  \Illuminate\Http\Request  $request
     */
    public function toArray($request): array
    {
        return [
            'id' => $this->id,
            'vault_id' => $this->vault_id,
            'first_name' => $this->first_name,
            'last_name' => $this->last_name,
            'middle_name' => $this->middle_name,
            'nickname' => $this->nickname,
            'maiden_name' => $this->maiden_name,
            'prefix' => $this->prefix,
            'suffix' => $this->suffix,
            'name' => NameHelper::formatContactName($request->user(), $this->resource),
            'job_position' => $this->job_position,
            'company' => $this->company ? [
                'id' => $this->company->id,
                'name' => $this->company->name,
            ] : null,
            'is_listed' => (bool) $this->listed,
            'avatar_url' => $this->file_id !== null ? $this->avatar['content'] : null,
            'contact_information' => ContactInformationResource::collection($this->whenLoaded('contactInformations')),
            'addresses' => AddressResource::collection($this->whenLoaded('addresses')),
            'important_dates' => ContactImportantDateResource::collection($this->whenLoaded('importantDates')),
            'created_at' => DateHelper::getTimestamp($this->created_at),
            'updated_at' => DateHelper::getTimestamp($this->updated_at),
            'links' => [
                'self' => route('api.vaults.contacts.show', [
                    'vault' => $this->vault_id,
                    'contact' => $this->id,
                ]),
            ],
        ];
    }
}
